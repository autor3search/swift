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
    /// benchmark" target filter.
    ///
    /// **Path adjacency** is the ONLY automatic exclusion this applies. In practice a
    /// benchmark's helper targets live alongside it — nested under the same parent
    /// directory a benchmark target's own path sits in (e.g. a `Fixtures` target at
    /// `Benchmarks/Fixtures`, sibling to a benchmark target at `Benchmarks/Bench`).
    /// This excludes every non-test, non-benchmark target whose path falls under any
    /// benchmark target's PARENT directory, not merely a benchmark target's own exact
    /// path. It can be overly conservative — a genuine library target that shares a
    /// benchmark's parent directory would also land out of scope — but that is a
    /// loud, recoverable `out_of_scope` rejection at scope-gate time, preferable to a
    /// benchmark-shrinking edit sailing through silently.
    ///
    /// ## Why the target-dependency graph is NOT used here (round 2 of this task's
    /// review)
    ///
    /// An earlier version of this function also excluded the chosen benchmark
    /// target's declared `target_dependencies` (see `benchmarkHelperPaths(of:repo:)`
    /// below), on the theory that a dependency the benchmark pulls in but that lives
    /// nowhere near it is probably fixture data. That theory doesn't hold: SwiftPM's
    /// manifest has no field distinguishing "the algorithm I'm benchmarking" from
    /// "fixture data I feed it" — both show up identically in `target_dependencies`.
    /// Every automatic decision built on that signal is a guess, and both ways of
    /// making the guess were verified live to fail in a genuinely bad direction:
    ///
    /// - Excluding ALL declared dependencies unconditionally drove `scope` to empty
    ///   for an ordinary single-library-single-benchmark package (the common case),
    ///   and for a real library-plus-fixture pair it excluded BOTH, silently
    ///   reopening the exact hole the signal was meant to close.
    /// - A "greedy, floor of one" refinement (exclude declared dependencies one at a
    ///   time, in sorted-path order, never past the last remaining candidate) fixed
    ///   that specific case by accident of alphabetical ordering — `Sources/Bench
    ///   Fixtures` sorts before `Sources/Lib`, so the fixture happened to be tried
    ///   (and excluded) first. Renaming the same two targets `Sources/Alpha` (the
    ///   real library) and `Sources/ZHelper` (the fixture) flips the sort order:
    ///   `Alpha` is excluded first because the floor-of-one guard doesn't stop it
    ///   (two candidates remain), leaving `ZHelper` as the lone survivor — the real
    ///   library silently dropped from scope AND the fixture silently left in it.
    ///   Ordinary fixture names that sort late (`Helpers`, `Mocks`, `Stubs`,
    ///   `Support`, `TestData`) hit exactly this failure.
    ///
    /// Both attempts guess, and a wrong guess here is silent — indistinguishable from
    /// a correct scope, which is the one outcome this project never accepts (see
    /// `ConfigError.emptyScope`'s own reasoning and the ruling recorded for this
    /// task). So `deriveScope` does not use the dependency graph at all any more.
    /// `target_dependencies` is still read (via `benchmarkHelperPaths(of:repo:)`),
    /// but only to power `scopedBenchmarkDependencyPaths`/`dependencyScopeWarning`
    /// below — a WARNING surfaced to the human after `init` succeeds, not a decision
    /// made on their behalf.
    static func deriveScope(from description: PackageDescription) -> [String] {
        let benchmarkTargets = description.benchmarkTargets
        let benchmarkNames = Set(benchmarkTargets.map(\.name))
        let pathAdjacencyRoots = Set(benchmarkTargets.map { parentDirectory(of: $0.path) })

        let candidates = description.targets.filter {
            $0.type != "test"
                && !benchmarkNames.contains($0.name)
                && !isBenchmarkAdjacent($0.path, roots: pathAdjacencyRoots)
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

    /// Runs `swift package describe --type json` purely to recover
    /// `target_dependencies` for `targetName` — a field `PackageDescription` does not
    /// expose. Called from `run` (via `deriveScope`) in round 1 of this task's
    /// review; as of round 2, `deriveScope` no longer uses this at all (see its doc
    /// comment) — this is now called ONLY by `scopedBenchmarkDependencies` below, to
    /// power a warning, after `run` has already succeeded. `init` runs once per
    /// repository and is not on the measurement path, so a separate invocation for
    /// this is an acceptable cost.
    ///
    /// Throws rather than silently returning no dependencies on failure, matching
    /// this project's ethos of failing loud rather than silently treating "the check
    /// couldn't run" the same as "the check ran and found nothing."
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

    /// Which of the benchmark's declared dependency paths (`benchmarkHelperPaths`)
    /// ended up inside the generated `scope`, i.e. which ones the agent can actually
    /// edit. A path-adjacent helper (excluded automatically by `deriveScope`) never
    /// appears here, because it was never in scope to begin with — there is nothing
    /// to warn about for a target the agent already cannot touch. Pure and
    /// hermetically testable, separate from the I/O in `benchmarkHelperPaths(of:repo:)`.
    static func scopedBenchmarkDependencyPaths(scope: [String], benchmarkHelperPaths: Set<String>) -> [String] {
        benchmarkHelperPaths.filter { scope.contains("\($0)/**") }.sorted()
    }

    /// Renders the human-facing warning for a non-empty `scopedBenchmarkDependencyPaths`
    /// result, or `nil` when there is nothing to warn about. `init` cannot tell which
    /// of these targets hold code genuinely under test and which hold fixture or
    /// synthetic input data — see `deriveScope`'s doc comment for why it no longer
    /// guesses — so every path here is named, including ones that are almost
    /// certainly the real library under test: pretending to know which is which is
    /// exactly the mistake round 1 of this fix made.
    public static func dependencyScopeWarning(paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        return """
        The following targets are direct dependencies of the benchmark target, and are \
        currently editable by the agent because they fell inside the generated scope:

        \(paths.sorted().map { "  - \($0)" }.joined(separator: "\n"))

        autor3search-swift cannot tell which of these hold code genuinely under test and \
        which hold fixture data or synthetic inputs the benchmark merely consumes -- \
        SwiftPM's manifest carries no such distinction, so none of them were excluded \
        automatically. If any of them are fixture/input data rather than code under test, \
        remove them from scope in .autor3search/config.yaml now: an agent that can shrink \
        a benchmark's input can win without making anything faster.

        Do this before running `autor3search-swift baseline` -- baseline freezes \
        config.yaml's hash, so this is the last moment such a change is straightforward.
        """
    }

    /// Convenience wrapper for `InitCommand`: recomputes the dependency graph (a
    /// fresh `swift package describe`, since `run(repo:force:)`'s signature is frozen
    /// and does not return this) and resolves it against `config.scope`. Called AFTER
    /// `run` has already succeeded and written the config — a failure here should not
    /// be treated as `init` itself having failed, since the actual work is already
    /// done; see `InitCommand` for how it handles that.
    public static func scopedBenchmarkDependencies(config: Config, repo: URL) throws -> [String] {
        let helperPaths = try benchmarkHelperPaths(of: config.benchmarkTarget, repo: repo)
        return scopedBenchmarkDependencyPaths(scope: config.scope, benchmarkHelperPaths: helperPaths)
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
    /// existing-config check, `swift package describe` (target selection and scope),
    /// benchmark discovery, `Config.validate()`, and rendering both files to strings
    /// — happens BEFORE any file is touched. A refusal therefore never leaves a
    /// half-written
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

        let scope = deriveScope(from: description)

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

    /// Idempotently ensures `.gitignore` covers every file this tool writes
    /// inside the repository under test. Keyed on a marker comment rather than a raw
    /// substring match, so a re-run of `init` (with `--force`) never appends a
    /// duplicate block, whether `.gitignore` did not exist, already existed without
    /// this entry, or already has it from a previous `init`.
    ///
    /// Four entries. `.autor3search/config.yaml` itself is deliberately NOT
    /// among them — it is committed on purpose, since `baseline` hashes it and
    /// the scope/config-integrity gates depend on it being tracked. The other
    /// three are not cosmetic (spec.md 9: "The only harness outputs inside the
    /// repository are `results.tsv` ... and `run.log` ..., both gitignored by
    /// `init`"), plus one Task 20 adds for the same reason:
    ///
    /// - `.build/` — what `swift build` populates while this tool measures.
    /// - `results.tsv` — `eval` appends a row to this on every experiment, so from
    ///   the second experiment onward it is an untracked file sitting in the
    ///   repository. An agent that commits with `git add -A` would sweep it into
    ///   its commit, and `eval`'s scope gate — which compares the commit against
    ///   `frozenCommit` — would then reject that commit as `out_of_scope` for a
    ///   file the harness itself wrote. Ignoring it keeps the harness's own log out
    ///   of the diff it judges.
    /// - `run.log` — the same argument, for subprocess transcripts.
    /// - `.autor3search/profiles/` — where `profile` (Task 20) writes each
    ///   benchmark's raw sampler output (`<benchmark>.sample.txt`). It lives
    ///   INSIDE `.autor3search/`, whose `config.yaml` is tracked, so without this
    ///   entry a profiling run followed by `git add -A` would commit exactly the
    ///   same class of harness-output-as-agent-edit bug `results.tsv`/`run.log`
    ///   exist above to prevent, and `eval`'s scope gate would reject the commit.
    private static let gitignoreMarker = "# autor3search-swift"

    /// Not `private`: exercised directly by `InitRunnerTests` so idempotence can be
    /// verified without a full, toolchain-and-possibly-network-dependent `run()`.
    static func ensureGitignoreCoversBuildOutput(repo: URL) throws {
        let url = repo.appendingPathComponent(".gitignore")
        let block = "\(gitignoreMarker)\n.build/\nresults.tsv\nrun.log\n.autor3search/profiles/\n"
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
