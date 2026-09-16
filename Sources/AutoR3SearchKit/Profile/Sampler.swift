// Sources/AutoR3SearchKit/Profile/Sampler.swift
//
// `profile` gives the agent real profiler data so it stops guessing at hot
// paths. It reports HOT LINES, never a call tree: verified on this machine,
// release Swift inlines aggressively enough that a whole function body
// (`hot()`, `cold()` in the spike) can vanish into its caller's frame, with
// every sample landing on the CALL SITE's line rather than the callee's.
// Presenting that as function-level attribution would imply a precision the
// data does not have, so every report this file produces carries the
// caveat below, verbatim, and the return type is a flat `[HotLine]`, never
// a tree.
//
// TWO INDEPENDENT HALVES, because no single technique works everywhere:
//
//   1. CPU SAMPLING (`sample` on macOS, `perf` on Linux) needs a sampler the
//      OS is willing to let this process attach with. macOS: verified, no
//      sudo and no Xcode required, `sample <pid> <seconds>` just works.
//      Linux: `perf_event_paranoid` commonly blocks an unprivileged
//      process from sampling even its own children inside a container, and
//      when it does, `available()`/`profile` REFUSE LOUDLY with the exact
//      reason -- never silently produce an empty table that looks like "no
//      hot lines" instead of "could not measure at all".
//   2. INSTRUCTION AND MALLOC COUNTS come straight from `BenchmarkTool`
//      (`--metrics instructions --metrics mallocCountTotal`), which works
//      on every platform this tool supports, including the one where no
//      sampler is permitted at all. These are a HINT, never scored --
//      spec-wide rule, restated at the print site so nothing implies
//      otherwise.
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One aggregated line of the ranked report: this many CPU samples landed
/// with `file:line` as their (possibly inlined-into) attribution.
public struct HotLine: Equatable {
    public let file: String
    public let line: Int
    public let samples: Int

    public init(file: String, line: Int, samples: Int) {
        self.file = file
        self.line = line
        self.samples = samples
    }
}

/// One row of the cross-platform second half of the report: a metric name
/// exactly as `BenchmarkTool` labels it (its own header text, not a name we
/// invent), and that metric's row-50 value.
public struct MetricHint: Equatable {
    public let label: String
    public let p50: Double

    public init(label: String, p50: Double) {
        self.label = label
        self.p50 = p50
    }
}

public enum SamplerError: Error, CustomStringConvertible {
    /// No CPU sampler is permitted on this machine right now. Carries the
    /// SPECIFIC reason (missing binary, unreadable or too-strict
    /// `perf_event_paranoid`, unsupported platform) rather than a generic
    /// "unavailable", so an operator can actually act on it.
    case notPermitted(String)
    case buildFailed(String)
    case launchFailed(String)
    case toolFailed(String)
    /// The benchmark named produced NO output at all when run directly --
    /// the compiled binary does not register a benchmark by this name (a
    /// stale `config.yaml`, a rename on one side only, a typo). Checked and
    /// thrown BEFORE `parseSampleOutput` is even consulted: a filter that
    /// matches nothing still leaves a live pid for a few milliseconds, long
    /// enough for a sampler to catch real, symbolicated, plausible-looking
    /// argument-parsing/startup frames that have nothing to do with the
    /// benchmark asked for -- exactly the dangerous shape (a result that
    /// reads as a finding) this case exists to refuse instead of returning.
    case benchmarkNotFound(String)
    /// The benchmark DID run (produced real output) but the profiler
    /// attached (or tried to) and came away with nothing attributable --
    /// most often because its run finished before sampling could catch it
    /// on-CPU at all. Distinct from `toolFailed`: the tool itself did not
    /// error, there is simply nothing to rank, and that must be said
    /// plainly rather than shown as an empty table that looks identical to
    /// "measured, found nothing hot". Distinct from `.benchmarkNotFound`:
    /// this is only ever thrown once real output has already ruled that
    /// cause out, so the message never misattributes one for the other.
    case tooFastToSample(String)
    case metricsFailed(String)

    public var description: String {
        switch self {
        case .notPermitted(let detail):
            return "no CPU sampler is available here: \(detail)"
        case .buildFailed(let detail):
            return "could not build the binary to profile: \(detail)"
        case .launchFailed(let detail):
            return "could not launch the benchmark to profile: \(detail)"
        case .toolFailed(let detail):
            return "the sampler failed: \(detail)"
        case .benchmarkNotFound(let detail):
            return "benchmark not found in the profiled binary: \(detail)"
        case .tooFastToSample(let detail):
            return "nothing attributable was captured: \(detail)"
        case .metricsFailed(let detail):
            return "could not read instruction/malloc counts from BenchmarkTool: \(detail)"
        }
    }
}

public enum Sampler {
    /// Required verbatim in every human-facing report `profile` produces
    /// (Task 20 brief, step 4). Without it a ranked-by-line table implies a
    /// precision -- "this exact function is the hot one" -- that release
    /// Swift's inlining has already destroyed.
    public static let inliningCaveat =
        "release builds inline aggressively; samples are attributed to the enclosing frame's " +
        "line, not the inlined callee."

    /// Alongside the caveat above: what the ranked table actually is,
    /// spelled out because macOS `sample`'s call graph reports INCLUSIVE
    /// counts per frame (every ancestor of a leaf reports the same count as
    /// the leaf), so two DIFFERENT lines in the table are not mutually
    /// exclusive shares of one total -- they can both be "the same samples,
    /// counted again on the way up the stack". Framework/dependency frames
    /// that sit between the harness and the benchmark's own closure will
    /// often show the identical count as the line that actually did the
    /// work; that is not double-counted work, it is the same work reported
    /// at more than one point in the call chain.
    public static let inclusiveCountsCaveat =
        "each row's sample count is the number of samples whose call stack passed through that " +
        "line, not a line's exclusive share of a fixed total -- rows are not additive, and a " +
        "framework line sitting above your code in the call chain can show the same count as " +
        "the line that did the work."

    // =====================================================================
    // MARK: - Parsing (frozen: Task 20 brief's 3 tests, verbatim)
    // =====================================================================

    /// Matches a leading sample count (skipping over whatever the call
    /// graph's own tree-drawing indentation looks like -- on a real,
    /// multi-threaded call graph that is not just spaces and `+`: verified
    /// live against real `sample` output, a deeply nested branch is
    /// prefixed with a mix of `+`, `!`, `|` and `:` glyphs, e.g.
    /// `+ !     : | 792 closure ...`. Rather than enumerate every glyph
    /// `sample` might use, this skips any run of NON-DIGIT characters at
    /// the start of the line -- the count is, unconditionally, the first
    /// run of digits on a real sample row, since every prefix glyph and
    /// every symbol name is non-numeric) and a trailing `file.swift:NN`.
    /// Everything between is free-form (symbol name, `+offset`, one or more
    /// `[0xADDR,...]` PC lists) and is not inspected: only the leading count
    /// and the final source location matter. Greedy `.*` finds the LAST
    /// `file.swift:NN` on the line, which is the one that matters when a
    /// line embeds other numbers (addresses, offsets) that happen to look
    /// similar.
    private static let lineRegex: NSRegularExpression = {
        // `try!`: a fixed, hand-verified pattern. A failure here is a programmer error this
        // file's own tests catch immediately, not a runtime condition to recover from.
        try! NSRegularExpression(pattern: #"^[^0-9]*([0-9]+)\s+.*\s([^\s]+\.swift):([0-9]+)\s*$"#)
    }()

    /// Aggregates `sample`'s (or, on Linux, `perf`'s tallied) call-graph
    /// text by `(file, line)`, summing every matching row's leading count,
    /// and returns the result ranked hottest first. A line with no
    /// attributable `file.swift:NN` -- a header, a frame with no debug
    /// info, a thread label -- contributes nothing and is silently skipped;
    /// that is normal, not an error, since most of a real call graph is
    /// exactly this (dyld, libdispatch, the runloop).
    public static func parseSampleOutput(_ text: String) -> [HotLine] {
        struct Key: Hashable { let file: String; let line: Int }

        var totals: [Key: Int] = [:]
        var order: [Key] = []

        for substring in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = lineRegex.firstMatch(in: line, options: [], range: range),
                  let countRange = Range(match.range(at: 1), in: line),
                  let fileRange = Range(match.range(at: 2), in: line),
                  let lineNoRange = Range(match.range(at: 3), in: line),
                  let count = Int(line[countRange]),
                  let lineNo = Int(line[lineNoRange])
            else { continue }

            let key = Key(file: String(line[fileRange]), line: lineNo)
            if totals[key] == nil { order.append(key) }
            totals[key, default: 0] += count
        }

        return order
            .map { HotLine(file: $0.file, line: $0.line, samples: totals[$0] ?? 0) }
            .sorted {
                $0.samples != $1.samples
                    ? $0.samples > $1.samples
                    : ($0.file, $0.line) < ($1.file, $1.line)
            }
    }

    // =====================================================================
    // MARK: - Availability
    // =====================================================================

    /// `true` when this machine can actually attach a CPU sampler right
    /// now. Prefer `unavailableReason()` at a call site that can report
    /// WHY -- this is kept for the frozen interface and for a quick check
    /// where no explanation is needed.
    public static func available() -> Bool { unavailableReason() == nil }

    /// `nil` when a sampler is available; otherwise the SPECIFIC reason it
    /// is not, so `profile` can refuse loudly with something an operator
    /// can act on instead of a bare "unavailable".
    static func unavailableReason() -> String? {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sample") else {
            return "/usr/bin/sample is not present (or not executable) on this machine."
        }
        return nil
        #elseif os(Linux)
        guard linuxPerfPath() != nil else {
            return "no `perf` executable was found on this machine; profile has no CPU sampler " +
                "to attach with on Linux."
        }
        guard let paranoid = linuxPerfEventParanoid() else {
            return "/proc/sys/kernel/perf_event_paranoid could not be read, so whether perf can " +
                "attach to an unprivileged process cannot be determined here; profile treats " +
                "that as unavailable rather than guessing."
        }
        guard paranoid <= 1 else {
            return "/proc/sys/kernel/perf_event_paranoid is \(paranoid). Above 1, an " +
                "unprivileged process cannot CPU-sample even its own children on most kernels " +
                "-- the common case inside an unprivileged container. Ask an operator to lower " +
                "it (e.g. `sysctl kernel.perf_event_paranoid=1`) or grant CAP_PERFMON, or rely " +
                "on the cross-platform instruction/malloc counts alone."
        }
        return nil
        #else
        return "no supported CPU sampler exists for this platform in autor3search-swift."
        #endif
    }

    #if os(Linux)
    private static func linuxPerfPath() -> String? {
        for candidate in ["/usr/bin/perf", "/usr/lib/linux-tools/perf", "/usr/local/bin/perf"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func linuxPerfEventParanoid() -> Int? {
        guard let text = try? String(
            contentsOf: URL(fileURLWithPath: "/proc/sys/kernel/perf_event_paranoid"), encoding: .utf8)
        else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    #endif

    // =====================================================================
    // MARK: - profile(): build, spawn, attach, parse
    // =====================================================================

    /// Builds `config.benchmarkTarget` in release WITH `-Xswiftc -g` (debug
    /// info -- see the file-level note in `ProfileCommand` for the MEASURED
    /// fact that `swift build -c release` already passes `-g` by default,
    /// so this changes nothing about what gets built), spawns it directly
    /// (not through `BenchmarkTool`; the target's own compiled binary
    /// accepts the same `--filter` a driver would pass it), attaches the
    /// platform's sampler for up to `seconds`, persists the raw output
    /// under `.autor3search/profiles/<benchmark>.sample.txt` inside
    /// `repo`, and returns the ranked, aggregated result.
    ///
    /// Throws `SamplerError.notPermitted` before touching the filesystem
    /// when no sampler is available; `.benchmarkNotFound` when `benchmark`
    /// produced no output at all when run directly (the compiled binary
    /// does not actually register a benchmark by this name -- checked
    /// BEFORE looking at what the sampler caught, since a filter that
    /// matches nothing still leaves a live pid for a few milliseconds, and
    /// whatever real, symbolicated, plausible-looking startup/argument-
    /// parsing code the sampler happens to catch in that window has
    /// nothing to do with the benchmark asked for); and `.tooFastToSample`
    /// when the benchmark DID run (real output was produced) but the
    /// sampler came away with nothing attributable regardless. Never
    /// returns an empty array pretending that is the same thing as
    /// "measured, and nothing was hot".
    public static func profile(
        benchmark: String, repo: URL, config: Config, seconds: Double
    ) throws -> [HotLine] {
        if let reason = unavailableReason() {
            throw SamplerError.notPermitted(reason)
        }

        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        let timeout = TimeInterval(config.timeoutSeconds)

        try build(swift: swift, repo: repo, product: config.benchmarkTarget,
                   extraFlags: ["-Xswiftc", "-g"], timeout: timeout)
        // `BenchmarkTool` needs no debug info -- only the benchmark
        // target's own binary is ever attached to -- but it must exist for
        // the metrics half below, and a bare `swift build` does not
        // produce a dependency's executable product (see `EvalRunner`).
        try build(swift: swift, repo: repo, product: "BenchmarkTool", extraFlags: [], timeout: timeout)

        let exe = repo.appendingPathComponent(".build/release/\(config.benchmarkTarget)")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw SamplerError.buildFailed(
                "built \(config.benchmarkTarget) in release but \(exe.path) is not present")
        }

        let escaped = NSRegularExpression.escapedPattern(for: benchmark)
        let child: SpawnedChild
        do {
            child = try POSIXSpawn.spawn(
                executable: exe, args: ["--filter", "^\(escaped)$", "--quiet", "true"],
                cwd: repo, env: nil)
        } catch {
            throw SamplerError.launchFailed("could not launch \(exe.path): \(error)")
        }

        // Same reason `eval` installs this trap around its own long-running
        // children: a Ctrl-C (or `stop --force`, though nothing currently
        // sends `profile` a stop request) must kill this child's whole
        // process-group tree, not leave it orphaned and burning CPU.
        //
        // `profile` holds TWO children alive at once for the whole sampling
        // window below -- this benchmark, and (inside `runSampleTool`/
        // `runPerfTool`) the sampler attached to it -- which is exactly the
        // case `SignalTrap`'s registry now has multiple slots for. A `false`
        // return means the registry is completely full; refuse rather than
        // let this child run untracked by the trap for the whole sampling
        // window, the same policy `Subprocess.runRaw` applies to every
        // other child this project spawns.
        guard SignalTrap.noteChildSpawned(pgid: child.pid) else {
            Platform.processTree.killTree(pgid: child.pid)
            var reapStatus: Int32 = 0
            waitpid(child.pid, &reapStatus, 0)
            close(child.stdoutFD)
            close(child.stderrFD)
            throw SamplerError.launchFailed(
                "SignalTrap's live-child registry is full; refusing to run \(exe.path) " +
                "untracked by the SIGTERM/SIGINT trap")
        }

        // The benchmark's own stdout is CAPTURED, not discarded: it is the
        // signal `benchmark` actually exists in this binary (see the
        // `.benchmarkNotFound` check below) -- verified live, the raw
        // executable run standalone with `--filter` prints its own full
        // results to stdout even under `--quiet true` when the filter
        // matches something, and prints NOTHING AT ALL, in well under
        // 50ms, when it matches nothing. Stderr is drained but not
        // inspected. Either way the pipes must be drained or a full 64 KiB
        // buffer would block the benchmark on a write while the sampler is
        // attached to it.
        let outDrain = CapturingDrain(fd: child.stdoutFD)
        let errDrain = CapturingDrain(fd: child.stderrFD)

        defer {
            // Best-effort: a no-op if the benchmark already exited on its
            // own, which is the common case -- `sample`/`perf` below waits
            // no longer than `seconds`, and most benchmarks finish well
            // inside that.
            Platform.processTree.killTree(pgid: child.pid)
            var status: Int32 = 0
            waitpid(child.pid, &status, 0)
            SignalTrap.noteChildReaped(pgid: child.pid)
            outDrain.wait()
            errDrain.wait()
            close(child.stdoutFD)
            close(child.stderrFD)
        }

        let raw: String
        #if os(macOS)
        raw = try runSampleTool(pid: child.pid, seconds: seconds, benchmark: benchmark, timeout: timeout)
        #elseif os(Linux)
        raw = try runPerfTool(pid: child.pid, seconds: seconds, repo: repo, timeout: timeout)
        #else
        throw SamplerError.notPermitted(unavailableReason() ?? "unsupported platform")
        #endif

        // Checked BEFORE inspecting what the sampler caught -- see the
        // extended reasoning in this function's doc comment. A snapshot is
        // safe here (before the child has necessarily been reaped): the
        // drain threads are already running in the background and append
        // under lock as bytes arrive, independent of when this is read.
        guard !outDrain.snapshot().isEmpty else {
            throw SamplerError.benchmarkNotFound("""
                "\(benchmark)" produced no output at all when run directly against \(exe.path) \
                with --filter ^\(escaped)$. The compiled binary does not appear to register a \
                benchmark by this name -- config.yaml and the benchmark target's source may have \
                gone out of sync, or the name has a typo. Nothing was profiled.
                """)
        }

        try persistRawOutput(raw, benchmark: benchmark, repo: repo)

        let hot = parseSampleOutput(raw)
        guard !hot.isEmpty else {
            throw SamplerError.tooFastToSample("""
                "\(benchmark)" ran -- it produced real output -- but the sampler attached to pid \
                \(child.pid) and captured no attributable samples in \(seconds)s. The most likely \
                cause: this benchmark's own run finished before sampling could catch anything \
                on-CPU -- a lightly-loaded benchmark body can complete in well under a second, \
                faster than most samplers can reliably attach to a freshly spawned process. Raise \
                this benchmark's own duration or iteration count (or profile a heavier workload) \
                to give the sampler something to catch. The raw (near-empty) sampler output was \
                still written to \(rawOutputURL(repo: repo, benchmark: benchmark).path).
                """)
        }
        return hot
    }

    // =====================================================================
    // MARK: - The metrics half: instructions and malloc, from BenchmarkTool
    // =====================================================================

    /// Runs `BenchmarkTool` with `--metrics instructions --metrics
    /// mallocCountTotal` (REPEATED flags -- verified live that a
    /// comma-joined `--metrics instructions,mallocCountTotal` is silently
    /// accepted by `ArgumentParser` and produces ZERO percentile tables and
    /// exit 0, which would otherwise look like a clean, empty result
    /// instead of a malformed invocation) and returns each metric's
    /// row-50 value, labelled with `BenchmarkTool`'s own header text.
    ///
    /// These numbers are a HINT, never scored -- spec-wide rule, restated
    /// at the print site in `ProfileCommand` so nothing about this table
    /// implies otherwise.
    public static func metricHints(
        benchmark: String, repo: URL, config: Config, storage: URL
    ) throws -> [MetricHint] {
        let tool = repo.appendingPathComponent(".build/release/BenchmarkTool")
        let exe = repo.appendingPathComponent(".build/release/\(config.benchmarkTarget)")
        let escaped = NSRegularExpression.escapedPattern(for: benchmark)

        let r = try Subprocess.run(tool, [
            "--command", "run",
            "--format", "histogramPercentiles",
            "--time-units", "nanoseconds",
            "--path", "stdout",
            "--no-progress",
            "--metrics", "instructions",
            "--metrics", "mallocCountTotal",
            "--grouping", "benchmark",
            "--filter", "^\(escaped)$",
            "--benchmark-executable-paths", exe.path,
            "--baseline-storage-path", storage.path,
            "--target-name", config.benchmarkTarget,
            "--targets", config.benchmarkTarget,
        ], cwd: repo, env: nil, timeout: TimeInterval(config.timeoutSeconds))

        guard !r.timedOut else {
            throw SamplerError.metricsFailed(
                "BenchmarkTool did not finish within timeout_seconds (\(config.timeoutSeconds)s)")
        }
        guard r.exitCode == 0 else {
            throw SamplerError.metricsFailed("BenchmarkTool exited \(r.exitCode): \(r.stderr)")
        }
        return try parseMetricHints(r.stdout)
    }

    /// Splits `stdout` on every `Percentile\t...` header (one per
    /// requested metric, in whatever order `BenchmarkTool` chose to emit
    /// them -- NOT necessarily the order `--metrics` was passed in,
    /// verified live) and reads each table's row 50, labelling the result
    /// with the header's own text rather than the `--metrics` key that
    /// requested it, since the two do not read the same
    /// (`mallocCountTotal` prints as `Malloc (total)`).
    static func parseMetricHints(_ stdout: String) throws -> [MetricHint] {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let headerIndices = lines.indices.filter { lines[$0].hasPrefix("Percentile") }
        guard !headerIndices.isEmpty else {
            throw SamplerError.metricsFailed("BenchmarkTool produced no percentile table")
        }

        var hints: [MetricHint] = []
        for headerIndex in headerIndices {
            let headerCols = lines[headerIndex].split(separator: "\t", omittingEmptySubsequences: true)
            guard headerCols.count >= 2 else { continue }
            var label = headerCols[1].trimmingCharacters(in: .whitespaces)
            if label.hasSuffix("*") {
                label = String(label.dropLast()).trimmingCharacters(in: .whitespaces)
            }

            var p50: Double?
            for line in lines[(headerIndex + 1)...] {
                if line.hasPrefix("Percentile") { break }
                let cols = line.split(separator: "\t", omittingEmptySubsequences: true)
                guard cols.count >= 2, cols[0].trimmingCharacters(in: .whitespaces) == "50" else { continue }
                p50 = Double(cols[1].trimmingCharacters(in: .whitespaces))
                break
            }
            guard let value = p50 else {
                throw SamplerError.metricsFailed("BenchmarkTool's \(label) percentile table has no row 50")
            }
            hints.append(MetricHint(label: label, p50: value))
        }
        return hints
    }

    // =====================================================================
    // MARK: - Platform sampler invocations
    // =====================================================================

    #if os(macOS)
    /// `sample <pid> <seconds>`, verified to need no sudo and no Xcode: it
    /// attaches to a pid this process spawned and exits 0. If the target
    /// has already exited by the time `sample` gets to it -- a real race
    /// against a benchmark fast enough to finish before the sampler can
    /// attach -- `sample` exits non-zero with a message naming the pid as
    /// no longer running; that specific case is reported as
    /// `.tooFastToSample` rather than a generic tool failure, since it is
    /// the SAME condition `profile` also detects from an empty parse.
    private static func runSampleTool(
        pid: pid_t, seconds: Double, benchmark: String, timeout: TimeInterval
    ) throws -> String {
        let sample = URL(fileURLWithPath: "/usr/bin/sample")
        let r = try Subprocess.run(
            sample, [String(pid), String(seconds)],
            cwd: URL(fileURLWithPath: "/"),
            timeout: max(timeout, seconds + 30))

        guard !r.timedOut else {
            throw SamplerError.toolFailed(
                "sample did not finish within \(Int(seconds) + 30)s and was killed")
        }
        guard r.exitCode == 0 else {
            let detail = r.stderr.isEmpty ? r.stdout : r.stderr
            if detail.lowercased().contains("no longer appears to be running")
                || detail.lowercased().contains("not found")
                || detail.lowercased().contains("no such process") {
                throw SamplerError.tooFastToSample("""
                    "\(benchmark)" exited before sample could attach to pid \(pid): \
                    \(detail.trimmingCharacters(in: .whitespacesAndNewlines))
                    """)
            }
            throw SamplerError.toolFailed("sample exited \(r.exitCode): \(detail)")
        }
        return r.stdout
    }
    #endif

    #if os(Linux)
    /// UNVERIFIED on real hardware -- written and reasoned through, but
    /// this project's spike machine is macOS-only, and `available()`
    /// already refuses loudly (the primary, VERIFIED Linux behaviour, per
    /// the measured fact that an unprivileged container's
    /// `perf_event_paranoid` commonly blocks this outright) before this
    /// function is ever reached in the common case.
    ///
    /// `perf record -p <pid> --call-graph dwarf ... -- sleep <seconds>`
    /// attaches to the live pid and stops after `seconds` (the dummy
    /// `sleep` target is `perf record`'s idiom for "run for this long,
    /// then stop", mirroring `sample <pid> <seconds>` on macOS). Unlike
    /// `sample`'s own aggregated call graph, `perf script` prints one line
    /// PER sampled event with no leading count, so this tallies
    /// `file.swift:NN` occurrences itself and hands `parseSampleOutput`
    /// pre-aggregated `"<count> ... file.swift:NN"` lines rather than raw
    /// `perf script` output -- the two tools' native shapes are different
    /// enough that routing perf's raw text through the macOS-shaped parser
    /// unchanged would not work.
    private static func runPerfTool(
        pid: pid_t, seconds: Double, repo: URL, timeout: TimeInterval
    ) throws -> String {
        guard let perf = linuxPerfPath() else {
            throw SamplerError.notPermitted(unavailableReason() ?? "no perf executable found")
        }
        let perfURL = URL(fileURLWithPath: perf)
        let dataFile = repo.appendingPathComponent(".autor3search/profiles/.perf-\(pid).data")
        try FileManager.default.createDirectory(
            at: dataFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataFile) }

        let record = try Subprocess.run(perfURL, [
            "record", "-p", String(pid), "--call-graph", "dwarf", "-o", dataFile.path,
            "--", "/bin/sleep", String(seconds),
        ], cwd: repo, env: nil, timeout: max(timeout, seconds + 30))
        guard !record.timedOut else {
            throw SamplerError.toolFailed("perf record did not finish within \(Int(seconds) + 30)s")
        }
        guard record.exitCode == 0 else {
            throw SamplerError.toolFailed("perf record exited \(record.exitCode): \(record.stderr)")
        }

        let script = try Subprocess.run(perfURL, [
            "script", "-i", dataFile.path, "-F", "ip,sym,srcline",
        ], cwd: repo, env: nil, timeout: timeout)
        guard script.exitCode == 0 else {
            throw SamplerError.toolFailed("perf script exited \(script.exitCode): \(script.stderr)")
        }

        // One perf-script line per sampled event, no count -- tally
        // `file.swift:NN` occurrences into the count-prefixed shape
        // `parseSampleOutput` expects, so both platforms share one parser.
        let srclineRegex = try? NSRegularExpression(pattern: #"([^\s/]+\.swift):([0-9]+)"#)
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in script.stdout.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let regex = srclineRegex,
                  let match = regex.firstMatch(in: s, options: [], range: range),
                  let matchRange = Range(match.range, in: s)
            else { continue }
            let key = String(s[matchRange])
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: "\n")
    }
    #endif

    // =====================================================================
    // MARK: - Building, output paths, small helpers
    // =====================================================================

    private static func build(
        swift: URL, repo: URL, product: String, extraFlags: [String], timeout: TimeInterval
    ) throws {
        let r = try Subprocess.run(
            swift, ["build", "-c", "release", "--product", product] + extraFlags,
            cwd: repo, timeout: timeout)
        guard !r.timedOut else {
            throw SamplerError.buildFailed(
                "building \(product) did not finish within timeout_seconds (\(Int(timeout))s)")
        }
        guard r.exitCode == 0 else {
            throw SamplerError.buildFailed("could not build \(product): \(String(r.stderr.suffix(4000)))")
        }
    }

    /// Where the raw sampler output for `benchmark` is written, inside the
    /// repository under test. Not gitignored by an older `init`-written
    /// `.gitignore` unless the entry was added by this task -- see
    /// `InitRunner.ensureGitignoreCoversBuildOutput`.
    public static func rawOutputURL(repo: URL, benchmark: String) -> URL {
        repo.appendingPathComponent(".autor3search/profiles/\(sanitizedFilename(benchmark)).sample.txt")
    }

    private static func persistRawOutput(_ text: String, benchmark: String, repo: URL) throws {
        let url = rawOutputURL(repo: repo, benchmark: benchmark)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A benchmark name is an arbitrary string from `config.benchmarks`; this
    /// keeps it to a single safe path component so it cannot escape
    /// `.autor3search/profiles/` (a `/` or `..` in a benchmark name would
    /// otherwise let it write anywhere in the repository).
    private static func sanitizedFilename(_ name: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped)
        return result.isEmpty ? "_" : result
    }
}

/// Drains a pipe read end to EOF in the background, capturing every byte
/// (bounded to `cap`) into a lock-guarded buffer that can be inspected
/// mid-flight via `snapshot()` -- used by `Sampler.profile` to tell "the
/// benchmark ran and printed real output" from "the filter matched nothing
/// and it exited immediately with none" -- as well as after `wait()`. The
/// pipe must still be drained regardless of whether anything reads the
/// capture: a full 64 KiB buffer would otherwise block the child on a
/// write while the sampler is attached to it.
private final class CapturingDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()
    // 1 MiB: ample for the existence check this exists for (the raw
    // executable's own results report), not a general-purpose capture --
    // callers that need the FULL stream use `Subprocess.run`/`runData`.
    private let cap = 1 << 20

    init(fd: Int32) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.group.leave() }
            let capacity = 64 * 1024
            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { readBuffer.deallocate() }
            while true {
                let n = read(fd, readBuffer, capacity)
                if n <= 0 { break }  // EOF, or the fd was torn down under us.
                self.append(readBuffer, count: n)
            }
        }
    }

    private func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let room = cap - captured.count
        guard room > 0 else { return }  // Keep reading (never block the child); discard past cap.
        captured.append(bytes, count: min(room, count))
    }

    /// A point-in-time copy of everything captured so far. Safe to call
    /// before `wait()` -- the read loop appends under `lock` from its own
    /// thread regardless of when this is read.
    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func wait() { group.wait() }
}
