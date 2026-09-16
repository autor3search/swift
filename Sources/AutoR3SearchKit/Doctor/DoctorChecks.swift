// Sources/AutoR3SearchKit/Doctor/DoctorChecks.swift
//
// `doctor` answers one question: can THIS machine, right now, measure
// reliably enough that a human should trust an unattended overnight run on
// it? It is INFORMATIONAL and ALWAYS EXITS 0 (`DoctorCommand` never throws) —
// its whole job is to be read before trusting numbers, not to block anything.
//
// SHAPE: every judgment below is a PURE FUNCTION over INJECTED FACTS. The
// thing that actually reads the machine (`pmset`, `sysctl`, `uptime`,
// `xcode-select`, `FileManager`'s volume capacity, `swift package describe`,
// `git status`, an actual `swift build`) lives only in `all(repo:)`'s probe
// helpers at the bottom of this file. A judging function never shells out
// and never touches the filesystem, which is what makes
// `warnsWhenXCTestIsMissing` and friends deterministic on any machine the
// TESTS happen to run on, including one where every fact below is the
// opposite of true.
//
// Two policy choices worth stating up front:
//
//   1. EVERY probe degrades to a reported "could not determine" instead of
//      throwing. `doctor` must never fail the command — not on a repo with
//      no Package.swift, not on a machine missing `pmset`, not when
//      `swift package describe` itself fails. `all(repo:)` therefore never
//      calls `try` without `?` or a `do`/`catch` that turns a failure into a
//      Finding. A `Level` has only `.ok`/`.warn` (no third "unknown" case,
//      per the fixed interface), so "could not determine" is reported as
//      `.warn` — the one thing it must never do is silently look identical
//      to "checked and fine".
//   2. DO NOT OVER-WARN. A doctor that prints ten scary lines on a healthy
//      machine trains people to stop reading it. `DoctorRunner` (the
//      executable-facing formatter, in `DoctorCommand.swift`) prints an
//      explicit all-clear when every Finding is `.ok`, and nothing else —
//      no reassuring boilerplate before each `.ok` line, just the fact.
import Foundation

/// The judgement of one check. Two levels, not three, deliberately — see the
/// file comment on how "could not determine" is represented.
public enum Level: Equatable, Sendable {
    case ok, warn
}

/// One line of doctor's report. `title` is a short, stable label a human can
/// scan; `detail` carries the actual explanation and, for a `.warn`, the fix.
public struct Finding: Equatable, Sendable {
    public let level: Level
    public let title: String
    public let detail: String

    public init(level: Level, title: String, detail: String) {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

public enum DoctorChecks {

    // =====================================================================
    // MARK: - Pure judgements (the five from the brief, verbatim signatures)
    // =====================================================================

    /// The headline check. Verified at spike time: Command Line Tools alone
    /// do NOT ship the real `XCTest.framework` — only the private
    /// `XCTestSupport.framework` sits under the CLT SDKs — so a repository
    /// with XCTest test targets fails to build with "unable to resolve
    /// module dependency: 'XCTest'". `eval`'s gate 6 runs the repository's
    /// OWN tests, so a CLT-only machine simply cannot gate such a repo, and
    /// the failure it would hit is obscure. swift-testing based test targets
    /// are unaffected either way, and on Linux `swift-corelibs-xctest` ships
    /// with the toolchain, so this check only ever fires on Darwin.
    public static func xctestAvailability(developerDir: String?, hasXCTestFramework: Bool) -> Finding {
        if hasXCTestFramework {
            return Finding(
                level: .ok,
                title: "XCTest availability",
                detail: "XCTest.framework is available (developer directory: \(developerDir ?? "unknown")). " +
                    "A repository with XCTest test targets can be built and gated normally here."
            )
        }
        let location = developerDir.map { "the active developer directory is \($0)" }
            ?? "no active developer directory could be determined (`xcode-select -p` failed)"
        return Finding(
            level: .warn,
            title: "XCTest availability",
            detail: """
                XCTest.framework was not found -- \(location). Xcode's Command Line Tools alone do \
                not ship the real XCTest.framework, only the private XCTestSupport.framework, so a \
                repository with XCTest test targets fails to build here with "unable to resolve \
                module dependency: 'XCTest'". `eval`'s gate 6 runs the repository's OWN tests, so a \
                repo with any XCTest target cannot be gated on this machine at all -- and that failure \
                is obscure unless you already know to look for it. swift-testing based test targets \
                are unaffected. Fix: install Xcode (not just the Command Line Tools) from the App \
                Store or developer.apple.com, then run \
                `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
                """
        )
    }

    /// macOS throttles CPU frequency under Low Power Mode, which inflates
    /// timing noise for the exact reason this harness cares about noise at
    /// all: a quiet machine's own run-to-run variance is already wide enough
    /// to manufacture a spurious regression (see `competingLoad` below for
    /// the measured evidence), and Low Power Mode makes that worse on purpose.
    public static func lowPowerMode(_ enabled: Bool) -> Finding {
        guard enabled else {
            return Finding(level: .ok, title: "Low Power Mode", detail: "Low Power Mode is off.")
        }
        return Finding(
            level: .warn,
            title: "Low Power Mode",
            detail: """
                Low Power Mode is ON. macOS throttles CPU frequency under Low Power Mode, which \
                inflates run-to-run timing noise and can manufacture a spurious regression on a \
                multi-hour unattended run. Turn it off before measuring: System Settings > Battery \
                (or Energy on a desktop), or `sudo pmset -a lowpowermode 0` from a script.
                """
        )
    }

    /// Most laptops throttle under battery power for the same reason as Low
    /// Power Mode -- and an overnight run is exactly long enough to run the
    /// battery down mid-run, ending the measurement outright.
    public static func power(onAC: Bool) -> Finding {
        guard !onAC else {
            return Finding(level: .ok, title: "Power source", detail: "Running on AC power.")
        }
        return Finding(
            level: .warn,
            title: "Power source",
            detail: """
                Running on battery power. Most laptops throttle CPU frequency on battery to conserve \
                charge, which inflates benchmark noise and can manufacture a spurious regression -- \
                and a multi-hour unattended run risks running the battery down before it finishes. \
                Plug in before starting one.
                """
        )
    }

    /// The harness keeps a SECOND full build directory for the pinned
    /// baseline worktree, alongside the repository's own `.build` -- so the
    /// effective disk budget for a run is roughly double one release build's
    /// footprint, not one. Running out mid-run fails in whatever way the
    /// filesystem happens to fail a partial write, which is a much worse
    /// diagnostic experience than `doctor` saying so up front.
    public static func diskSpace(freeBytes: Int64) -> Finding {
        let thresholdBytes: Int64 = 20_000_000_000 // 20 GB
        let freeGB = Double(freeBytes) / 1_000_000_000
        guard freeBytes < thresholdBytes else {
            return Finding(level: .ok, title: "Free disk space",
                            detail: String(format: "%.1f GB free.", freeGB))
        }
        return Finding(
            level: .warn,
            title: "Free disk space",
            detail: String(format: """
                Only %.1f GB free. Swift release build directories are large, and this harness keeps \
                a SECOND one for the pinned baseline worktree in addition to the repository's own \
                `.build` -- an unattended run can exhaust disk partway through and fail in whatever \
                way the filesystem happens to fail a partial write. Free up space (aim for at least \
                20 GB) before a long run.
                """, freeGB)
        )
    }

    /// One round is one `BenchmarkTool` process invocation per side
    /// (`MeasureSession` samples baseline then candidate, `config.count`
    /// times, per benchmark) -- so the total process-run count scales
    /// directly with `benchmarks.count * count * 2`, on top of one release
    /// build and one `swift test` per `eval` call, neither counted here.
    public static func expectedRunLength(config: Config, secondsPerRound: Double) -> Finding {
        let processRuns = config.benchmarks.count * config.count * 2
        let estimatedSeconds = Double(processRuns) * secondsPerRound
        return Finding(
            level: .ok,
            title: "Expected measurement length",
            detail: String(format: """
                %d benchmark(s) x %d round(s) x 2 sides = %d process runs for one `eval`. At roughly \
                %.2fs per round (process-launch-plus-run; varies with the benchmark) that is about \
                %@ of measurement time alone -- on top of one release build and one `swift test`, \
                neither counted here. Multiply by however many experiments the agent's loop plans to \
                run overnight.
                """, config.benchmarks.count, config.count, processRuns, secondsPerRound,
                Self.humanDuration(estimatedSeconds))
        )
    }

    // =====================================================================
    // MARK: - Additional pure judgements (required scope beyond the brief)
    // =====================================================================

    /// Informational only -- core layout by itself is neither good nor bad,
    /// just a fact worth having on hand when interpreting noise elsewhere in
    /// this report. `nil` (sysctl unavailable, e.g. not Apple silicon or not
    /// Darwin at all) is reported rather than guessed at.
    public static func coreCounts(performance: Int?, efficiency: Int?) -> Finding {
        guard let performance, let efficiency else {
            return Finding(
                level: .warn,
                title: "CPU core counts",
                detail: "Could not determine performance/efficiency core counts " +
                    "(`sysctl hw.perflevel0.logicalcpu` / `hw.perflevel1.logicalcpu`) -- " +
                    "probably not Apple silicon, or sysctl is unavailable on this platform."
            )
        }
        return Finding(level: .ok, title: "CPU core counts",
                        detail: "\(performance) performance + \(efficiency) efficiency logical CPUs.")
    }

    /// Another process competing for cycles is drift by another name: it
    /// lands unevenly on whichever side of the interleaved baseline/candidate
    /// comparison happens to be running when it spikes. Warns once the
    /// 1-minute load average claims more than half the logical CPUs.
    public static func competingLoad(loadAverage1m: Double?, logicalCPUs: Int?) -> Finding {
        guard let loadAverage1m, let logicalCPUs, logicalCPUs > 0 else {
            return Finding(
                level: .warn,
                title: "Competing load",
                detail: "Could not determine system load (`uptime`) or the total logical CPU count -- " +
                    "cannot judge how much of the machine other processes are using. Check manually " +
                    "with `uptime` and `top` before a long run."
            )
        }
        let busyFraction = loadAverage1m / Double(logicalCPUs)
        guard busyFraction > 0.5 else {
            return Finding(level: .ok, title: "Competing load",
                            detail: String(format: "1-minute load average is %.2f against %d logical CPUs.",
                                            loadAverage1m, logicalCPUs))
        }
        return Finding(
            level: .warn,
            title: "Competing load",
            detail: String(format: """
                1-minute load average is %.2f against %d logical CPUs (%.0f%% of capacity already \
                claimed by other processes). Competing load lands unevenly across an interleaved \
                baseline/candidate comparison and inflates noise. Close other applications before an \
                unattended run.
                """, loadAverage1m, logicalCPUs, busyFraction * 100)
        )
    }

    /// `eval` now REFUSES a dirty working tree outright -- it builds and
    /// measures the WORKING TREE while the scope gate inspects committed
    /// diffs, so an uncommitted edit would be measured but never gated -- and
    /// `baseline` refuses one too. Telling a human here means they find out
    /// from `doctor`, not from a refused `eval` partway through a plan.
    /// `nil` covers "not a readable git repository at this path at all".
    public static func workingTree(clean: Bool?) -> Finding {
        guard let clean else {
            return Finding(
                level: .warn,
                title: "Working tree",
                detail: "Could not determine whether the working tree is clean -- this does not look " +
                    "like a readable git repository (or `git status` failed). `baseline` and `eval` " +
                    "both require one; run doctor again from inside the repository you intend to measure."
            )
        }
        guard clean else {
            return Finding(
                level: .warn,
                title: "Working tree",
                detail: """
                    The working tree has uncommitted changes. `eval` builds and measures the WORKING \
                    TREE while the scope gate inspects committed diffs, so an uncommitted edit would be \
                    measured but never gated -- so both `baseline` and `eval` refuse to run at all on a \
                    dirty tree. A common innocent cause is an untracked Package.resolved; commit or \
                    .gitignore it, then commit or stash whatever else is left.
                    """
            )
        }
        return Finding(level: .ok, title: "Working tree", detail: "Clean -- no uncommitted changes.")
    }

    /// The softest link in the whole chain (flagged in `eval`'s own review):
    /// gate 6 runs the repository's OWN tests, which `@testable import` the
    /// code under optimization -- so a test gated with `.enabled(if:)` /
    /// `.disabled(if:)`, or on an environment variable, or an `XCTSkip`, can
    /// be switched off from IN-SCOPE library code the agent is free to edit,
    /// WITHOUT touching any frozen file. `Package.swift` is frozen and the
    /// test files are frozen and restored every experiment, but the
    /// CONDITION such a gate reads can live entirely in optimizable code.
    /// There is no clean fix, so this surfaces what it finds for a human to
    /// look at rather than pretending to catch every case -- it is a
    /// heuristic, not a guarantee: a plain substring match, not an AST walk,
    /// so it can both miss a disguised condition and flag an innocent
    /// comment or string containing the same text.
    public static func conditionalTestGating(hits: [String]) -> Finding {
        guard !hits.isEmpty else {
            return Finding(
                level: .ok,
                title: "Conditionally-gated tests",
                detail: "No `.enabled(if:)`, `.disabled(if:)`, `ProcessInfo.processInfo.environment`, " +
                    "or `XCTSkip` usage found in the frozen test target directories."
            )
        }
        let shown = hits.prefix(20).joined(separator: "\n    ")
        let more = hits.count > 20 ? "\n    ... and \(hits.count - 20) more" : ""
        return Finding(
            level: .warn,
            title: "Conditionally-gated tests",
            detail: """
                Found \(hits.count) place(s) in the frozen test target directories that could disable \
                a test conditionally:
                    \(shown)\(more)
                This is a HEURISTIC (a plain text match, not an AST walk), not a guarantee -- it can \
                both miss a disguised condition and flag an innocent comment. Review each hit before \
                trusting an unattended run: a test gated on a condition that lives in IN-SCOPE library \
                code can be switched off by the agent without ever touching a frozen file.
                """
        )
    }

    /// Whether `.autor3search/config.yaml` exists at all. Always `.ok` --
    /// running `doctor` before `init` is an expected, ordinary state, not a
    /// problem to warn about. `all(repo:)` uses this to decide whether the
    /// build and run-length checks (which both need `Config`) are meaningful
    /// to attempt.
    public static func packageConfiguration(configured: Bool) -> Finding {
        guard configured else {
            return Finding(
                level: .ok,
                title: "Configuration",
                detail: "No .autor3search/config.yaml yet -- run `autor3search-swift init` before " +
                    "`baseline`/`eval`. The benchmark-build and expected-run-length checks below are " +
                    "skipped until then."
            )
        }
        return Finding(level: .ok, title: "Configuration", detail: ".autor3search/config.yaml found.")
    }

    /// Judges the OUTCOME of an actual build attempt `all(repo:)` performs
    /// (`swift build -c release --product <benchmarkTarget>` and
    /// `--product BenchmarkTool`, BY NAME). A bare `swift build -c release`
    /// does NOT produce `BenchmarkTool` -- it is a dependency's executable
    /// product -- so this check exists specifically to catch that before an
    /// unattended `eval` hits `benchmark_build_failed` for the first time
    /// hours into a run.
    public static func measurementBuild(succeeded: Bool, detail: String) -> Finding {
        guard succeeded else {
            return Finding(
                level: .warn,
                title: "Benchmark build",
                detail: """
                    Building the measurement products failed: \(detail)
                    A bare `swift build -c release` does not produce `BenchmarkTool` -- it is a \
                    dependency's executable product and needs `--product BenchmarkTool` explicitly, \
                    which is what this check ran. `eval` will refuse the same way with \
                    `benchmark_build_failed`; fix the build before trusting an unattended run.
                    """
            )
        }
        return Finding(level: .ok, title: "Benchmark build",
                        detail: "`swift build -c release --product <benchmarkTarget>` and " +
                            "`--product BenchmarkTool` both succeeded.")
    }

    private static func humanDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%.1fm", minutes) }
        return String(format: "%.1fh", minutes / 60)
    }

    // =====================================================================
    // MARK: - Report formatting (pure, so it is testable without a machine)
    // =====================================================================

    /// Renders `findings` (in the order `all(repo:)` produced them) as the
    /// text `DoctorCommand` prints verbatim. Deliberately CALM on a healthy
    /// machine: every `.ok` line is one line, no reassuring boilerplate
    /// before it, and the summary at the end is the only place that says
    /// anything extra -- a single explicit all-clear when there is nothing
    /// to fix, so a human reading past ten `[OK]` lines still gets a clear
    /// verdict rather than having to count them.
    public static func report(findings: [Finding], repo: URL) -> String {
        var lines: [String] = []
        lines.append("autor3search-swift doctor")
        lines.append("  repository: \(repo.path)")
        lines.append("")
        for finding in findings {
            let tag = finding.level == .ok ? "[OK]  " : "[WARN]"
            lines.append("\(tag) \(finding.title)")
            for detailLine in finding.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("       \(detailLine)")
            }
            lines.append("")
        }
        let warnCount = findings.filter { $0.level == .warn }.count
        if warnCount == 0 {
            lines.append("All checks passed. This machine looks fit for an unattended run.")
        } else {
            lines.append("\(warnCount) check(s) need attention -- see WARN lines above before trusting an unattended run.")
        }
        return lines.joined(separator: "\n")
    }

    // =====================================================================
    // MARK: - `all(repo:)` -- the only place that reads the real machine
    // =====================================================================

    /// Runs every check against the real machine and `repo`, in report
    /// order, headline first. Never throws: every probe below degrades to a
    /// reported "could not determine" `Finding` instead, per the file
    /// comment's policy (1).
    public static func all(repo: URL) -> [Finding] {
        var findings: [Finding] = []

        // --- XCTest availability (headline) ---
        let developerDir = probeDeveloperDir()
        findings.append(xctestAvailability(
            developerDir: developerDir,
            hasXCTestFramework: probeHasXCTestFramework(developerDir: developerDir)))

        // --- Low Power Mode / power source ---
        let power = probePower()
        findings.append(lowPowerMode(power.lowPowerModeOn))
        findings.append(Self.power(onAC: power.onAC))

        // --- CPU layout / competing load ---
        let performanceCores = probeSysctlInt("hw.perflevel0.logicalcpu")
        let efficiencyCores = probeSysctlInt("hw.perflevel1.logicalcpu")
        findings.append(coreCounts(performance: performanceCores, efficiency: efficiencyCores))

        let totalLogicalCPUs = probeSysctlInt("hw.logicalcpu")
            ?? { (p: Int?, e: Int?) -> Int? in
                guard let p, let e else { return nil }
                return p + e
            }(performanceCores, efficiencyCores)
        findings.append(competingLoad(loadAverage1m: probeLoadAverage1m(), logicalCPUs: totalLogicalCPUs))

        // --- Disk space ---
        if let freeBytes = probeFreeBytes(at: repo) {
            findings.append(diskSpace(freeBytes: freeBytes))
        } else {
            findings.append(Finding(level: .warn, title: "Free disk space",
                                     detail: "Could not determine free disk space at \(repo.path)."))
        }

        // --- Working tree cleanliness ---
        findings.append(workingTree(clean: try? Git(repo: repo).isClean()))

        // --- Conditionally-gated tests: needs `swift package describe` ---
        if let description = try? PackageDescribe.describe(repo: repo) {
            let testDirs = description.testTargets.map(\.path)
            findings.append(conditionalTestGating(hits: scanForConditionalGating(repo: repo, testDirs: testDirs)))
        } else {
            findings.append(Finding(
                level: .warn,
                title: "Conditionally-gated tests",
                detail: "Could not run `swift package describe` in \(repo.path) -- is this a readable " +
                    "Swift package? Skipping the scan for conditionally-gated tests."))
        }

        // --- Config-dependent checks: need .autor3search/config.yaml ---
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        guard let config = try? Config.load(configURL) else {
            findings.append(packageConfiguration(configured: false))
            return findings
        }
        findings.append(packageConfiguration(configured: true))
        findings.append(expectedRunLength(config: config, secondsPerRound: 1.0))

        let buildOutcome = probeMeasurementBuild(repo: repo, config: config)
        findings.append(measurementBuild(succeeded: buildOutcome.succeeded, detail: buildOutcome.detail))

        return findings
    }

    // =====================================================================
    // MARK: - Probes (the only impure code in this file)
    // =====================================================================

    private static let swiftBinary = URL(fileURLWithPath: "/usr/bin/swift")

    /// `xcode-select -p`, trimmed. `nil` if the command fails to launch or
    /// exits non-zero (no developer directory configured at all).
    private static func probeDeveloperDir() -> String? {
        guard let result = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"],
            cwd: URL(fileURLWithPath: "/"), timeout: 10),
            result.exitCode == 0
        else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Verified real path: Xcode's `XCTest.framework` lives at
    /// `<developer dir>/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework`.
    /// Command Line Tools alone never have this file -- only the private
    /// `.../SDKs/MacOSX*.sdk/System/Library/PrivateFrameworks/XCTestSupport.framework`,
    /// which is a different, unrelated framework.
    private static func probeHasXCTestFramework(developerDir: String?) -> Bool {
        guard let developerDir else { return false }
        let path = developerDir +
            "/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"
        return FileManager.default.fileExists(atPath: path)
    }

    /// `pmset -g` reports `lowpowermode 0`/`1`. `pmset -g batt` reports which
    /// source is currently in use as its first line; a desktop with no
    /// battery at all is treated as AC (never positively "on battery"),
    /// which is the correct default for the machine this was verified on
    /// (Apple silicon desktop, no `-InternalBattery-0` entry at all on some
    /// configurations).
    private static func probePower() -> (lowPowerModeOn: Bool, onAC: Bool) {
        let pmset = URL(fileURLWithPath: "/usr/bin/pmset")
        let root = URL(fileURLWithPath: "/")

        var lowPowerModeOn = false
        if let r = try? Subprocess.run(pmset, ["-g"], cwd: root, timeout: 10), r.exitCode == 0 {
            for line in r.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("lowpowermode") {
                    lowPowerModeOn = trimmed.hasSuffix("1")
                }
            }
        }

        var onAC = true
        if let r = try? Subprocess.run(pmset, ["-g", "batt"], cwd: root, timeout: 10), r.exitCode == 0 {
            onAC = !r.stdout.contains("Battery Power")
        }

        return (lowPowerModeOn, onAC)
    }

    /// `sysctl -n <name>`, parsed as an `Int`. `nil` on any failure --
    /// missing on non-Darwin, or the named sysctl not existing on this
    /// machine (e.g. an Intel Mac has no `hw.perflevel1.logicalcpu`).
    private static func probeSysctlInt(_ name: String) -> Int? {
        guard let r = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", name],
            cwd: URL(fileURLWithPath: "/"), timeout: 10),
            r.exitCode == 0
        else { return nil }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `uptime`'s 1-minute load average. macOS spells the line
    /// `load averages: 2.38 4.41 5.19`; Linux spells it
    /// `load average: 0.10, 0.05, 0.01`. Both are handled by taking the first
    /// token after whichever spelling matches, stripping a trailing comma.
    private static func probeLoadAverage1m() -> Double? {
        guard let r = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/uptime"), [],
            cwd: URL(fileURLWithPath: "/"), timeout: 10),
            r.exitCode == 0
        else { return nil }
        let output = r.stdout
        for marker in ["load averages:", "load average:"] {
            guard let range = output.range(of: marker) else { continue }
            let rest = output[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let firstToken = rest.split(separator: " ").first else { continue }
            let cleaned = firstToken.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            return Double(cleaned)
        }
        return nil
    }

    /// Free space at `path`'s volume via `URLResourceValues`, per the brief.
    /// Falls back to `FileManager.attributesOfFileSystem` if the resource
    /// value is unavailable (some volume types do not report the
    /// "important usage" key).
    private static func probeFreeBytes(at path: URL) -> Int64? {
        if let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// Substring markers for the conditional-test-gating heuristic. Order
    /// does not matter here (unlike `UnsafeDetector`'s constructs): none of
    /// these strings is a prefix of another.
    private static let conditionalGatingMarkers = [
        ".enabled(if:", ".disabled(if:", "ProcessInfo.processInfo.environment", "XCTSkip",
    ]

    /// Walks every `.swift` file under each declared test target directory
    /// and reports `"path:line: <trimmed line>"` for every line containing
    /// one of `conditionalGatingMarkers`. Deliberately a plain substring
    /// scan, not an AST walk or even comment/string stripping -- see
    /// `conditionalTestGating`'s doc comment on why this is a heuristic, not
    /// a guarantee, and why that is stated rather than hidden.
    private static func scanForConditionalGating(repo: URL, testDirs: [String]) -> [String] {
        var hits: [String] = []
        for dir in testDirs.sorted() {
            let dirURL = repo.appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            var files: [URL] = []
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                files.append(fileURL)
            }
            for fileURL in files.sorted(by: { $0.path < $1.path }) {
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let relativePath = fileURL.path.hasPrefix(repo.path)
                    ? String(fileURL.path.dropFirst(repo.path.count + 1))
                    : fileURL.path
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    for marker in conditionalGatingMarkers where line.contains(marker) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        hits.append("\(relativePath):\(index + 1): \(trimmed)")
                        break
                    }
                }
            }
        }
        return hits
    }

    /// Actually builds, BY NAME, the two executables `eval` needs before it
    /// can measure anything: the configured benchmark target and
    /// `BenchmarkTool` itself (a dependency's product, so a bare
    /// `swift build -c release` would leave it absent -- see
    /// `EvalRunner.buildMeasurementProducts`, which this reuses directly
    /// rather than re-implementing the same two-product build a second way).
    /// Runs in `repo` itself, not a copy: a doctor run for a repository is a
    /// statement about THAT repository's own `.build`, matching what `swift
    /// build` run by hand would do.
    private static func probeMeasurementBuild(repo: URL, config: Config) -> (succeeded: Bool, detail: String) {
        do {
            let failure = try EvalRunner.buildMeasurementProducts(
                swift: swiftBinary, in: repo, benchmarkTarget: config.benchmarkTarget,
                timeout: TimeInterval(config.timeoutSeconds), reasonPrefix: "doctor_benchmark_build",
                where: "the repository under test")
            guard let failure else { return (true, "") }
            return (false, failure.detail)
        } catch {
            return (false, "\(error)")
        }
    }
}
