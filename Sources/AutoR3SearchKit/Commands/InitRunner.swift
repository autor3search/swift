// Sources/AutoR3SearchKit/Commands/InitRunner.swift
//
// `init` discovers benchmarks, writes autor3search.yaml's config and
// program.md, and REFUSES to configure a repository it cannot measure. The
// refusal is the important behaviour here: this tool has no other notion of
// "faster" than the declared benchmarks' timings. With none declared, every
// candidate would be accepted for no reason or rejected for no reason.
import Foundation

public enum InitError: Error, CustomStringConvertible {
    case noBenchmarks
    case configExists

    /// `swift package describe` reported more than one target carrying the
    /// `Benchmark` product dependency. `Config.benchmarkTarget` is a single
    /// `String` — there is no way to represent "measure these two targets"
    /// in the frozen config shape, and silently picking one (the first
    /// found, the alphabetically-first name, ...) would be a policy
    /// decision made without the human's knowledge, exactly the kind of
    /// silent guess this tool exists to avoid making. So this refuses too,
    /// the same way `noBenchmarks` does, and tells the human what a fix
    /// looks like instead of picking for them.
    case multipleBenchmarkTargets(names: [String])

    public var description: String {
        switch self {
        case .configExists:
            return "config already exists; pass --force to overwrite"
        case .multipleBenchmarkTargets(let names):
            return """
            Found \(names.count) benchmark targets, not one: \(names.sorted().joined(separator: ", ")).

            autor3search-swift's config names exactly one benchmark target
            (benchmark_target in config.yaml is a single string), and picking one of several
            targets on the agent's behalf, without telling a human, is exactly the kind of
            silent guess this tool exists to avoid.

            To use autor3search-swift on this repository:

              - Consolidate your benchmarks into a single executable target that depends on
                the "Benchmark" product (one target can declare as many `Benchmark("Name") { }`
                entries as you like), or
              - Remove the "Benchmark" product dependency from all but one of these targets,
                so only the one you want measured remains a benchmark target.

            Then re-run autor3search-swift init.
            """
        case .noBenchmarks:
            return """
            No benchmarks found, so no config was written.

            This tool has no other notion of "faster": the verdict is entirely a function of
            the declared benchmarks' timings across a baseline and a candidate. With none
            declared, every candidate would be accepted for no reason or rejected for no reason.

            To use autor3search-swift on this repository:

              1. Add the benchmark package to Package.swift:
                   .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.0")
                 and a benchmark target depending on the "Benchmark" product with the
                 "BenchmarkPlugin" plugin.

              2. Write at least one benchmark. Note the nonisolated(unsafe), which is
                 required under Swift 6 language mode:

                   import Benchmark
                   nonisolated(unsafe) let benchmarks = {
                       Benchmark("Thing") { benchmark in
                           for _ in benchmark.scaledIterations { blackHole(thing()) }
                       }
                   }

              3. Benchmark the right thing. A benchmark that exercises a cold path, a
                 trivial helper, or a function nobody calls under load produces numbers
                 that are entirely real and entirely useless. Benchmark what actually
                 dominates the workload you care about, ideally informed by a profile
                 rather than a guess.

              4. Re-run autor3search-swift init.
            """
        }
    }
}

public enum InitRunner {
    public static func validateDiscovered(_ names: [String]) throws {
        guard !names.isEmpty else { throw InitError.noBenchmarks }
    }

    /// Parses `Benchmark("Name", ...)` declarations out of benchmark target source.
    ///
    /// A call site is only recognised when the literal text `Benchmark(` survives
    /// `UnsafeDetector.stripCommentsAndStrings` unchanged at that offset — inside a
    /// comment or a string literal the stripper blanks that span to spaces, so it can
    /// never match there. That handles `// Benchmark("NotReal") { }` correctly: the
    /// whole comment, "Benchmark(" included, is blank in the stripped text.
    ///
    /// The name itself is then read from the ORIGINAL source at the same offset,
    /// because the stripper blanks string-literal content — including the quote
    /// characters — which destroys exactly the text this function needs to recover.
    /// `cleaned` and `original` are both built by iterating the same `Character`
    /// array and preserve length/line structure 1:1 by construction, so offsets found
    /// in one are valid offsets into the other.
    ///
    /// A name built by interpolation (`Benchmark("\(prefix)Name")`), by string
    /// concatenation (`Benchmark("A" + "B")`, `Benchmark("A" + suffix)`), or a first
    /// argument that isn't a string literal at all (`Benchmark(someConstant)`) cannot
    /// be resolved statically. All are skipped rather than guessed at: a fabricated
    /// or mangled name would silently end up in config.yaml and mismatch whatever the
    /// benchmark executable actually registers at runtime — worse than not
    /// discovering that one benchmark, because `validateDiscovered` would see a
    /// non-empty list and `init` would succeed with a config that can never match a
    /// real benchmark filter (a zero-match `BenchmarkTool` filter run produces no
    /// percentile table, which `MetricSource` turns into a confusing failure at
    /// measurement time, far from the config that actually caused it). A concatenated
    /// literal is detected by a `+` immediately after the closing quote (skipping
    /// whitespace) — `"A" + "B"` and `"A" + suffix` both trip it. A `+` before the
    /// opening quote (`prefix + "A"`) never reaches that check at all: the argument
    /// then doesn't start with `"`, so it is already caught by the plain "not a
    /// string literal" branch below.
    public static func discoverBenchmarks(benchmarkSource: String) -> [String] {
        let cleaned = Array(UnsafeDetector.stripCommentsAndStrings(benchmarkSource))
        let original = Array(benchmarkSource)
        guard cleaned.count == original.count else { return [] }

        let needle = Array("Benchmark(")
        var names: [String] = []
        var i = 0
        while i + needle.count <= cleaned.count {
            guard Array(cleaned[i..<(i + needle.count)]) == needle else {
                i += 1
                continue
            }
            var j = i + needle.count
            while j < original.count, original[j] == " " || original[j] == "\t" || original[j] == "\n" {
                j += 1
            }
            guard j < original.count, original[j] == "\"" else {
                // Not a string literal (e.g. a constant reference): unresolvable, skip.
                i += needle.count
                continue
            }
            j += 1
            var name = ""
            var unresolvable = false
            var closed = false
            while j < original.count {
                let c = original[j]
                if c == "\\", j + 1 < original.count, original[j + 1] == "(" {
                    // String interpolation: not statically resolvable. Skip past the
                    // balanced parens of the interpolated expression and keep scanning
                    // for the literal's close, but remember not to trust the result.
                    unresolvable = true
                    var depth = 1
                    j += 2
                    while j < original.count, depth > 0 {
                        if original[j] == "(" { depth += 1 }
                        if original[j] == ")" { depth -= 1 }
                        j += 1
                    }
                    continue
                }
                if c == "\\", j + 1 < original.count {
                    // Ordinary escape: \" contributes a literal quote; everything else
                    // (\\, \n, \u{...}, ...) is dropped rather than reproduced, since an
                    // escaped control character has no business in a benchmark name.
                    if original[j + 1] == "\"" { name.append("\"") }
                    j += 2
                    continue
                }
                if c == "\"" {
                    closed = true
                    j += 1
                    // A `+` immediately after this closing quote (module whitespace)
                    // means the literal is being concatenated with something else —
                    // `"A" + "B"` or `"A" + suffix`. The name registered at runtime
                    // would be the full concatenation, which cannot be resolved
                    // statically; treat it the same as an interpolation rather than
                    // reporting the truncated left-hand literal as the whole name.
                    var k = j
                    while k < original.count, original[k] == " " || original[k] == "\t" || original[k] == "\n" {
                        k += 1
                    }
                    if k < original.count, original[k] == "+" { unresolvable = true }
                    break
                }
                name.append(c)
                j += 1
            }
            if closed, !unresolvable, !name.isEmpty { names.append(name) }
            i = max(j, i + needle.count)
        }
        return names
    }

    /// All benchmark declarations found under `target`'s directory in `repo`,
    /// gathered by recursively reading every `.swift` file there and discovering
    /// names from each. `PackageDescription` does not expose per-target source file
    /// lists (only `name`/`type`/`path`/`productDependencies`), so the target's
    /// directory is walked directly rather than trusting a manifest-reported file
    /// list that isn't available here. Files are visited in a fixed (sorted) order
    /// so the resulting benchmark list is deterministic across runs.
    static func discoverBenchmarks(repo: URL, target: SwiftTarget) throws -> [String] {
        let dir = repo.appendingPathComponent(target.path)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var swiftFiles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            swiftFiles.append(url)
        }
        swiftFiles.sort { $0.path < $1.path }

        var names: [String] = []
        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            names.append(contentsOf: discoverBenchmarks(benchmarkSource: source))
        }
        return names
    }

    /// The scope this repository's agent may edit: the paths of every target that is
    /// neither a test target, a benchmark target, nor BENCHMARK-ADJACENT (see below),
    /// each turned into a `<path>/**` glob.
    ///
    /// Deliberately never `["**"]`. A benchmark HELPER target — one holding fixture
    /// data or a synthetic dataset that the benchmark consumes but does not itself
    /// depend on the `Benchmark` product — is not frozen (freeze detection keys on
    /// that product dependency), so it would be writable by the agent under a
    /// blanket scope, or even under a scope built from a naive "not a test, not a
    /// benchmark" target filter. Two independent signals close this, applied together
    /// ("belt and braces" — each catches a layout the other misses):
    ///
    /// 1. **Path adjacency.** In practice a benchmark's helper targets live alongside
    ///    it — nested under the same parent directory a benchmark target's own path
    ///    sits in (e.g. a `Fixtures` target at `Benchmarks/Fixtures`, sibling to a
    ///    benchmark target at `Benchmarks/Bench`). This excludes every non-test,
    ///    non-benchmark target whose path falls under any benchmark target's PARENT
    ///    directory, not merely a benchmark target's own exact path.
    /// 2. **The target-dependency graph** (`benchmarkHelperPaths`, resolved by the
    ///    caller from a local decode of `target_dependencies` — see
    ///    `benchmarkHelperPaths(of:repo:)` below). This catches a helper that is a
    ///    *declared dependency* of the benchmark target but lives nowhere near it,
    ///    e.g. `Sources/BenchFixtures` alongside a real library at `Sources/Lib` and a
    ///    benchmark at `Benchmarks/Bench` — path adjacency alone misses this entirely,
    ///    since `Sources/BenchFixtures` doesn't nest under `Benchmarks`.
    ///
    /// Both signals can be overly conservative — a genuine library target that shares
    /// a benchmark's parent directory could land out of scope under signal 1. That is
    /// a loud, recoverable `out_of_scope` rejection at scope-gate time, preferable to
    /// a benchmark-shrinking edit sailing through silently, so signal 1 always
    /// applies unconditionally.
    ///
    /// Signal 2 needs more care: `benchmarkHelperPaths` is every DIRECT target
    /// dependency of the chosen benchmark, and in a real package that set almost
    /// always includes the actual library under test alongside any genuine fixture
    /// helpers — SwiftPM's manifest has no field distinguishing "the algorithm I'm
    /// benchmarking" from "fixture data I feed it," so both show up identically in
    /// `target_dependencies`. Excluding the whole set unconditionally was tried and
    /// rejected during this fix's round 1: verified live against a real, working
    /// single-library-single-benchmark package, it drove `scope` to empty — turning
    /// `init` into a hard refusal for the single most common package shape this tool
    /// exists to support, and (worse) against the THREE-target layout this signal was
    /// added for (real library + fixture helper, both direct dependencies of the
    /// benchmark) it excluded BOTH, re-emptying scope and backing out of the
    /// exclusion entirely — silently reopening the exact hole this signal exists to
    /// close.
    ///
    /// So exclusion here is greedy with a floor of one: helper paths are tried in a
    /// fixed (sorted) order, each excluded only if at least one non-test,
    /// non-benchmark target would still remain afterward. For the common shape (one
    /// real library, zero or more genuine fixture helpers) this excludes every
    /// fixture and leaves the library — verified live against exactly that layout.
    /// The known remaining gap: if a benchmark genuinely depends on MORE than one
    /// real, independently-optimizable library target (not just one library plus
    /// fixtures), this floor stops at whichever one target happens to sort last and
    /// excludes the rest — safe-direction-wrong (an `out_of_scope` rejection the
    /// human can fix by widening `scope` by hand), not silent-direction-wrong, but a
    /// real limitation worth flagging for whoever next revisits this.
    static func deriveScope(from description: PackageDescription, benchmarkHelperPaths: Set<String> = []) -> [String] {
        let benchmarkTargets = description.benchmarkTargets
        let benchmarkNames = Set(benchmarkTargets.map(\.name))
        let pathAdjacencyRoots = Set(benchmarkTargets.map { parentDirectory(of: $0.path) })

        var candidates = description.targets.filter {
            $0.type != "test"
                && !benchmarkNames.contains($0.name)
                && !isBenchmarkAdjacent($0.path, roots: pathAdjacencyRoots)
        }

        for helperPath in benchmarkHelperPaths.sorted() {
            guard candidates.count > 1 else { break }
            candidates.removeAll { $0.path == helperPath }
        }

        let globs = Set(candidates.map { "\($0.path)/**" })
        return globs.sorted()
    }

    private static func parentDirectory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[..<idx])
    }

    /// Whether `path` sits at or under any of `roots`. An empty root (a benchmark
    /// target declared with no parent directory, i.e. living at the repository root)
    /// never matches anything here — excluding on an empty prefix would exclude every
    /// target in the package, which is a worse failure than not excluding at all.
    private static func isBenchmarkAdjacent(_ path: String, roots: Set<String>) -> Bool {
        roots.contains { root in
            !root.isEmpty && (path == root || path.hasPrefix(root + "/"))
        }
    }

    /// Local, minimal JSON shape for the ONE additional field this task needs out of
    /// `swift package describe --type json`: `target_dependencies`. Deliberately
    /// separate from Task 8's `PackageDescribe.Raw`/`SwiftTarget` — those are frozen
    /// interfaces Tasks 16 and 17 consume as-is, not to be modified here — rather than
    /// widening a shared, frozen decode shape for one task's narrow need.
    private struct RawTargetGraph: Decodable {
        struct Target: Decodable {
            let name: String
            let path: String
            let target_dependencies: [String]?
        }
        let targets: [Target]
    }

    /// Resolves `targetName`'s direct `target_dependencies` (same-package target
    /// references, as opposed to `productDependencies`) to their own `path`s, from
    /// already-fetched `swift package describe --type json` bytes. Split out from
    /// `benchmarkHelperPaths(of:repo:)` so the parse/resolve logic itself is testable
    /// against a literal JSON fixture, without a real `swift package describe`
    /// subprocess in the hot path of the test suite — mirroring how
    /// `PackageDescribeTests` tests `PackageDescribe.parse` against a fixture file
    /// rather than shelling out.
    static func parseTargetDependencyPaths(_ json: Data, of targetName: String) throws -> Set<String> {
        let graph: RawTargetGraph
        do {
            graph = try JSONDecoder().decode(RawTargetGraph.self, from: json)
        } catch {
            throw PackageDescribeError.failed("could not decode swift package describe output: \(error)")
        }
        guard let target = graph.targets.first(where: { $0.name == targetName }) else { return [] }
        let pathsByName = Dictionary(uniqueKeysWithValues: graph.targets.map { ($0.name, $0.path) })
        let depNames = target.target_dependencies ?? []
        return Set(depNames.compactMap { pathsByName[$0] })
    }

    /// Runs `swift package describe --type json` a second time (the first, via
    /// `PackageDescribe.describe`, already ran to build `description` in `run`) purely
    /// to recover `target_dependencies` for `targetName` — a field `PackageDescription`
    /// does not expose. Acceptable: `init` runs once per repository and is not on the
    /// measurement path.
    ///
    /// Throws rather than silently returning no exclusions on failure. This data feeds
    /// a safety-narrowing decision (`deriveScope`'s belt-and-braces exclusion set);
    /// silently treating a failure here as "no additional helpers found" would make a
    /// transient or environmental failure indistinguishable from a genuinely helper-
    /// free benchmark target, which is exactly the kind of silent guess this project's
    /// own ethos rejects everywhere else. The first `describe` call already proved the
    /// manifest parses and the toolchain works, so a failure here should be rare.
    static func benchmarkHelperPaths(of targetName: String, repo: URL, timeout: TimeInterval = 300) throws -> Set<String> {
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        let r = try Subprocess.run(swift, ["package", "describe", "--type", "json"],
                                    cwd: repo, env: nil, timeout: timeout)
        guard r.exitCode == 0 else { throw PackageDescribeError.failed(r.stderr) }
        guard !r.outputTruncated else {
            throw PackageDescribeError.failed("swift package describe output was truncated at the capture cap")
        }
        guard let start = r.stdout.firstIndex(of: "{") else {
            throw PackageDescribeError.failed("no JSON in output")
        }
        return try parseTargetDependencyPaths(Data(r.stdout[start...].utf8), of: targetName)
    }

    /// Picks the one target to measure, or refuses. Split out from `run` so the
    /// "no silent pick among several" policy can be tested directly against a
    /// fabricated `PackageDescription`, without needing a real `swift package
    /// describe` invocation (which needs a toolchain and, for a package that
    /// genuinely resolves two distinct `Benchmark`-product targets, network access).
    static func selectBenchmarkTarget(from description: PackageDescription) throws -> SwiftTarget {
        let benchmarkTargets = description.benchmarkTargets
        switch benchmarkTargets.count {
        case 0:
            throw InitError.noBenchmarks
        case 1:
            return benchmarkTargets[0]
        default:
            throw InitError.multipleBenchmarkTargets(names: benchmarkTargets.map(\.name))
        }
    }

    private static let defaultCount = 10
    private static let defaultAlpha = 0.05
    private static let defaultMinEffectPct = 1.0
    private static let defaultMaxRegressPct = 5.0
    private static let defaultTimeoutSeconds = 600

    private static func todayTag(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: now)
    }

    /// Discovers benchmarks, derives scope, writes `.autor3search/config.yaml` and
    /// `program.md`, and refuses (without writing anything) when the repository
    /// cannot be measured.
    ///
    /// Ordering matters for partial-write safety: every check that can refuse — the
    /// existing-config check, both `swift package describe` invocations (target
    /// selection and the target-dependency graph), benchmark discovery,
    /// `Config.validate()`, and rendering both files to strings — happens BEFORE any
    /// file is touched. A refusal therefore never leaves a half-written
    /// `.autor3search/` directory or a `program.md` with no matching config: either
    /// every write happens, or none does. The one thing this ordering cannot protect
    /// against is the filesystem itself failing partway through the write phase
    /// (disk full, permissions revoked mid-run) — an unavoidable risk for any
    /// multi-file writer without a journal, and orthogonal to the "refuses to
    /// configure what it cannot measure" behaviour this function exists to
    /// guarantee.
    @discardableResult
    public static func run(repo: URL, force: Bool) throws -> Config {
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        if !force, FileManager.default.fileExists(atPath: configURL.path) {
            throw InitError.configExists
        }

        let description = try PackageDescribe.describe(repo: repo)
        let chosenTarget = try selectBenchmarkTarget(from: description)

        let names = try discoverBenchmarks(repo: repo, target: chosenTarget)
        try validateDiscovered(names)

        let helperPaths = try benchmarkHelperPaths(of: chosenTarget.name, repo: repo)
        let scope = deriveScope(from: description, benchmarkHelperPaths: helperPaths)

        let config = Config(
            version: 1,
            scope: scope,
            benchmarkTarget: chosenTarget.name,
            benchmarks: names,
            count: defaultCount,
            alpha: defaultAlpha,
            minEffectPct: defaultMinEffectPct,
            maxRegressPct: defaultMaxRegressPct,
            timeoutSeconds: defaultTimeoutSeconds
        )
        // Belt-and-suspenders: if `scope` somehow came back empty (e.g. every
        // discovered target is a test or benchmark target), fail loudly here via the
        // same ConfigError the config would fail on at load time, rather than writing
        // a config that would only be rejected later, far from this point.
        try config.validate()

        let configText = try config.serialized()
        let tag = todayTag()
        let programMDText = ProgramMD.render(config: config, tag: tag)

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configText.write(to: configURL, atomically: true, encoding: .utf8)
        try programMDText.write(
            to: repo.appendingPathComponent("program.md"), atomically: true, encoding: .utf8)
        try ensureGitignoreCoversBuildOutput(repo: repo)

        return config
    }

    /// Idempotently ensures `.gitignore` covers `.build/` — the directory `swift
    /// build`/`swift package benchmark` populate inside the repository under test
    /// while this tool measures it. Keyed on a marker comment rather than a raw
    /// substring match, so a re-run of `init` (with `--force`) never appends a
    /// duplicate block, whether `.gitignore` did not exist, already existed without
    /// this entry, or already has it from a previous `init`.
    private static let gitignoreMarker = "# autor3search-swift"

    /// Not `private`: exercised directly by `InitRunnerTests` so idempotence can be
    /// verified without a full, toolchain-and-possibly-network-dependent `run()`.
    static func ensureGitignoreCoversBuildOutput(repo: URL) throws {
        let url = repo.appendingPathComponent(".gitignore")
        let block = "\(gitignoreMarker)\n.build/\n"
        guard FileManager.default.fileExists(atPath: url.path) else {
            try block.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard !existing.contains(gitignoreMarker) else { return }
        let needsNewline = !existing.isEmpty && !existing.hasSuffix("\n")
        let updated = existing + (needsNewline ? "\n" : "") + (existing.isEmpty ? "" : "\n") + block
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
