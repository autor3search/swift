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

    /// `swift package resolve` did not succeed, so whether this package needs
    /// a `Package.resolved` -- and therefore whether `init` has anything to
    /// commit before the freeze -- could not be established. Fatal rather
    /// than a warning: proceeding would leave the repository in exactly the
    /// state `baseline` now refuses, discovered one step later for no benefit.
    case dependencyResolveFailed(String)

    /// `Package.resolved` is named by an ignore rule. This is the state
    /// `doctor` itself used to RECOMMEND ("commit or .gitignore it"), and
    /// taking that branch leaves `packageResolvedSHA256` pinning the hash of
    /// zero bytes forever -- the tool's own remedy silently disabling the
    /// dependency pin gate 2 exists to enforce.
    case lockfileGitIgnored

    /// `swift package resolve` CHANGED an already-tracked `Package.resolved`,
    /// which means the committed lockfile and the manifest disagree. `init`
    /// refuses to commit that on the operator's behalf: a rewritten lockfile
    /// is a real dependency change, and quietly committing one under the
    /// banner of "setting up the harness" is precisely the kind of decision
    /// this tool does not make for people.
    case lockfileOutOfDate

    /// Staging or committing the harness prerequisites failed (no git
    /// identity configured, a hook rejecting the commit, an index lock).
    case prerequisiteCommitFailed(String)

    public var description: String {
        switch self {
        case .dependencyResolveFailed(let why):
            return """
            refusing to configure this repository: `swift package resolve` did not succeed \
            (\(why)).

            init has to know whether this package produces a \(Lockfile.name), because that file \
            must be TRACKED before `baseline` freezes anything. `swift package describe` (which \
            init also runs) never writes it, but `swift build` does, into the package root -- so \
            a repository left without a committed lockfile has every eval after the first fail \
            permanently, as manifest_change_rejected or dirty_working_tree, with no way out.

            Fix whatever stopped the resolve -- network, credentials for a private dependency, \
            an unreachable dependency URL -- and re-run init.
            """
        case .lockfileGitIgnored:
            return """
            refusing to configure this repository: \(Lockfile.name) is excluded by an ignore rule \
            (check .gitignore).

            An ignored lockfile cannot be pinned. baseline records its hash so the dependency set \
            cannot move mid-run; ignored, it is absent from frozenCommit, every later worktree \
            resolves its own, and the recorded pin describes a file no run is guaranteed to see. \
            Earlier versions of `autor3search-swift doctor` actively suggested this -- that advice \
            was wrong and has been removed.

            Fix: delete the \(Lockfile.name) line from .gitignore and re-run init.
            """
        case .lockfileOutOfDate:
            return """
            refusing to configure this repository: `swift package resolve` rewrote the tracked \
            \(Lockfile.name), so the committed lockfile and Package.swift disagree.

            That is a real dependency change, not harness setup, and init will not commit one on \
            your behalf. Review the diff and commit it yourself:

              git diff \(Lockfile.name)
              git add \(Lockfile.name) && git commit -m "update dependency pins"

            Then re-run init.
            """
        case .prerequisiteCommitFailed(let why):
            return """
            wrote the config, but could not commit the harness prerequisites (\(why)).

            \(Lockfile.name) and .gitignore have to be TRACKED before `baseline` freezes anything, \
            or the first eval's own build will leave an untracked lockfile behind and every \
            experiment after it will fail permanently. Commit them by hand and re-run baseline:

              git add \(Lockfile.name) .gitignore && git commit -m "pin dependencies"
            """
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

    // =====================================================================
    // MARK: - The defaults, and why they are what they are
    // =====================================================================
    //
    // These five constants ARE the KEEP rule for every repository that never
    // edits `config.yaml`, which is most of them. They were changed after a
    // measurement review found that the PREVIOUS defaults let a comment-only
    // commit clear both KEEP criteria on the shipped fixture.
    //
    // The specific finding, which is the reason for everything below: `init`
    // writes ONE benchmark for the fixture, so k = 1, so the
    // "Bonferroni-corrected" threshold alpha/k is NUMERICALLY IDENTICAL to the
    // uncorrected alpha. In the default configuration there is no correction
    // at all. Rule 2 was therefore being asked to hold the line at a bare 0.05
    // against two separately compiled binaries that are not exchangeable
    // samples -- and the run log records it failing to: arm B's spurious KEEP
    // (`ratio 0.98853, p 0.03546`, run-log Task 22) was a one-comment commit
    // that cleared both rules at these old defaults.

    /// Rounds per side. DELIBERATELY UNCHANGED at 10.
    ///
    /// Raising it is the intuitive response to a noisy verdict and it is the
    /// WRONG one here, for a reason the run log measures rather than asserts
    /// (Task 21, repeated in Task 22's arm design): the two sides are separate
    /// builds in separate directories, so their difference is a BIASED
    /// estimate, not noise about 1.0. More rounds per side make Mann-Whitney
    /// BETTER at resolving a biased estimate -- p shrinks and a drifting no-op
    /// reads MORE significant, not less. The reachability table does not force
    /// a change either: k = 1 is reachable from count 4 upward at the old
    /// alpha and from count 6 upward at the new one, both below 10.
    private static let defaultCount = 10

    /// 0.05 -> 0.005.
    ///
    /// This is nearly free and it is the cheapest factor of ten available.
    /// COST: the exact two-sided p-value floor at `count: 10` is
    /// `2 / C(20,10) = 2 / 184756 = 1.0825e-5` (bound by
    /// `theReachabilityTableIsCorrectAtTheShippedDefaultAlpha` in
    /// `InitRunnerTests`), so even after dividing by k the new alpha still
    /// admits **461** simultaneous benchmarks before a KEEP becomes
    /// unreachable -- `maxBenchmarksWithReachableKeep` floors, and
    /// `0.005 / 1.0825e-5 = 461.89`, so 461, not the 462 a ceiling would give
    /// and not the 4618 the old alpha gave. Nothing real is near either -- and a
    /// real win saturates the floor anyway (the run log's own 8.5x KEEP does).
    /// BENEFIT: every per-experiment false positive that reads between 0.005
    /// and 0.05 now discards. The run log's three recorded near-misses all sit
    /// in exactly that band -- arm B's spurious KEEP at p = 0.03546, and arm
    /// A's trials 14 (p = 0.03546) and 61 (p = 0.02881), which were caught by
    /// the effect floor alone and would now be caught twice.
    private static let defaultAlpha = 0.005

    /// 1.0 -> 3.0.
    ///
    /// The run log names this the load-bearing criterion: 2 of 100 arm-A
    /// trials were significant at the corrected alpha AND faster, and were
    /// stopped by NOTHING BUT this floor. A floor that the measurement noise
    /// itself can cross is not a floor, and 1.0 was one: arm A's largest
    /// excursion from 1.0 on identical code was 1.39% and arm B's was 3.215%
    /// (run-log Task 22). 3.0 sits above the first with room and is the
    /// smallest round number that does.
    private static let defaultMinEffectPct = 3.0

    /// 5.0 -> 3.0, chosen to be EQUAL to `defaultMinEffectPct`.
    ///
    /// At 1.0/5.0 the rule was indefensibly asymmetric: a change could regress
    /// one benchmark by 4.9% -- significantly, measurably -- and still be
    /// committed unattended on the strength of a 1.0% aggregate win. The
    /// harness would have been trading 4.9% of harm for 1.0% of benefit and
    /// calling it progress.
    ///
    /// Equality is the principle worth stating: NO SINGLE BENCHMARK MAY BE
    /// HARMED BY MORE THAN THE AGGREGATE WIN THE CHANGE IS REQUIRED TO
    /// DEMONSTRATE. Anything looser re-opens the trade above; anything tighter
    /// is not supported by measurement -- 2.0 was the alternative considered
    /// and rejected, because arm A's measured no-op excursion reaches 1.39%
    /// and rule 3 fires at the UNCORRECTED alpha, so a 2.0 guard leaves only
    /// 0.6 pp between ordinary build drift and an outright refusal. That
    /// direction of error is not harmless: it spends the loop's night
    /// DISCARDING real wins over drift nobody introduced.
    private static let defaultMaxRegressPct = 3.0

    private static let defaultTimeoutSeconds = 600

    /// Attaches the one comment the generated config needs, above
    /// `purge_build_output`.
    ///
    /// `purge_build_output: false` is the only key in this file whose default
    /// is a DELIBERATE TRADE rather than a value: it is off because turning it
    /// on roughly doubles the cost of every experiment, and a reader who finds
    /// a security switch defaulted to off deserves to be told the price in the
    /// same breath, not sent to the README to discover there was a price at
    /// all. `Yams` cannot emit comments, so it is spliced in here -- on the
    /// rendered text, once, before the file is written and therefore before
    /// `baseline` hashes those bytes.
    ///
    /// Written defensively: if the key is ever absent from the rendered YAML
    /// (a future encoder change, a hand-built `Config`), this returns the text
    /// untouched rather than guessing where the comment belongs. A missing
    /// comment is cosmetic; a comment spliced into the wrong line is a corrupt
    /// config.
    static func annotated(_ yaml: String) -> String {
        let key = "purge_build_output:"
        let comment = """
            # Delete every compiled artifact under .build before each side is built, so the
            # measured binaries come only from sources the gates hashed. OFF by default: it
            # roughly doubles the cost of an experiment (measured +33.6s on the demo package).
            # Dependencies are not re-resolved either way -- this is a cold build, not a
            # re-clone. See "The build cache is not verified" in the README.
            """
        var lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.hasPrefix(key) }) else { return yaml }
        lines.insert(contentsOf: comment.split(separator: "\n").map(String.init), at: index)
        return lines.joined(separator: "\n")
    }

    /// The config `init` writes, given the three things it had to discover.
    ///
    /// Extracted from `runReportingCommit` for ONE reason: until this existed,
    /// nothing in the test suite bound the shipped defaults, so the five
    /// numbers that ARE the KEEP rule for every repository that never edits
    /// `config.yaml` could be changed by anyone, in a one-character diff, with
    /// a green suite. `theShippedDefaultsAreWhatTheReviewSettledOn` in
    /// `InitRunnerTests` now fails if any of them moves, so moving one is a
    /// deliberate act with a diff that says so -- which is the whole point of
    /// freezing a policy in a constant rather than in a habit.
    ///
    /// Not `private`: the test reaches it through `@testable import`, and a
    /// value this load-bearing being untestable was the defect.
    static func defaultConfig(
        scope: [String], benchmarkTarget: String, benchmarks: [String]
    ) -> Config {
        Config(
            version: 1,
            scope: scope,
            benchmarkTarget: benchmarkTarget,
            benchmarks: benchmarks,
            count: defaultCount,
            alpha: defaultAlpha,
            minEffectPct: defaultMinEffectPct,
            maxRegressPct: defaultMaxRegressPct,
            timeoutSeconds: defaultTimeoutSeconds
        )
    }

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
    /// ROUND 2: the lockfile probe and its two refusals (`lockfileGitIgnored`,
    /// `lockfileOutOfDate`) moved AHEAD of the writes, so their wording --
    /// "refusing to configure this repository" -- is now literally true. In
    /// round 1 they ran as the last statement of `run`, after `config.yaml`,
    /// `program.md` and `.gitignore` were already on disk, and told the
    /// operator it was refusing to do something it had just done. Only the
    /// COMMIT stays at the end, where it belongs: there is nothing to commit
    /// until `.gitignore` has been written.
    @discardableResult
    public static func run(repo: URL, force: Bool) throws -> Config {
        try runReportingCommit(repo: repo, force: force).config
    }

    /// The single commit `init` makes, so `InitCommand` can announce it.
    ///
    /// An unannounced commit in someone else's repository is not acceptable
    /// even when it is the correct thing to do, so this carries exactly what a
    /// human needs to audit or undo it: the SHA and the paths.
    public struct HarnessCommit: Equatable, Sendable {
        public let sha: String
        public let paths: [String]
        public init(sha: String, paths: [String]) {
            self.sha = sha
            self.paths = paths
        }
    }

    /// What `init` did, including the commit it made (`nil` when nothing needed
    /// committing -- both files already tracked and unchanged).
    ///
    /// Separate from `run(repo:force:)` rather than a change to its return
    /// type: that signature is called from the integration tests and from
    /// `BaselineCommand`'s neighbourhood, and widening it would churn callers
    /// that do not care.
    public struct Outcome: Sendable {
        public let config: Config
        public let harnessCommit: HarnessCommit?
    }

    public static func runReportingCommit(repo: URL, force: Bool) throws -> Outcome {
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        if !force, FileManager.default.fileExists(atPath: configURL.path) {
            throw InitError.configExists
        }

        let description = try PackageDescribe.describe(repo: repo)
        let chosenTarget = try selectBenchmarkTarget(from: description)

        let names = try discoverBenchmarks(repo: repo, target: chosenTarget)
        try validateDiscovered(names)

        let scope = deriveScope(from: description)

        let config = defaultConfig(
            scope: scope, benchmarkTarget: chosenTarget.name, benchmarks: names)
        // Belt-and-suspenders: if `scope` somehow came back empty (e.g. every
        // discovered target is a test or benchmark target), fail loudly here via the
        // same ConfigError the config would fail on at load time, rather than writing
        // a config that would only be rejected later, far from this point.
        try config.validate()

        let configText = annotated(try config.serialized())
        let tag = todayTag()
        let programMDText = ProgramMD.render(config: config, tag: tag)

        // LAST refusal, and still ahead of the first write: resolve the
        // dependency graph and refuse an ignored or out-of-date lockfile now,
        // while "refusing to configure this repository" is a true statement.
        let requirement = try resolveLockfile(repo: repo)

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configText.write(to: configURL, atomically: true, encoding: .utf8)
        try programMDText.write(
            to: repo.appendingPathComponent("program.md"), atomically: true, encoding: .utf8)
        try ensureGitignoreCoversBuildOutput(repo: repo)
        let harnessCommit = try commitHarnessPrerequisites(
            repo: repo, paths: requirement.pathsToTrack)

        return Outcome(config: config, harnessCommit: harnessCommit)
    }

    // =====================================================================
    // MARK: - The dependency lockfile
    // =====================================================================

    /// Leaves the repository with a COMMITTED `Package.resolved`, if this
    /// package produces one at all -- and commits `.gitignore` along with it.
    ///
    /// WHY THIS HAS TO HAPPEN IN `init`. `swift package describe --type json`
    /// -- all `init` used to run -- exits 0 and writes no `Package.resolved`.
    /// `swift build -c release --product <X>` DOES write one, into the package
    /// ROOT (`--scratch-path` does not move it). So on any repository with
    /// source-control dependencies and no tracked lockfile, `baseline`
    /// recorded a hash of nothing, and the FIRST `eval`'s own build then
    /// created the file. From that moment the repository was permanently
    /// stuck: commit the lockfile and gate 1 answers
    /// `manifest_change_rejected`; leave it and gate 2b answers
    /// `dirty_working_tree`. Gate 1 diffs `frozenCommit..HEAD` and
    /// `frozenCommit` never advances, so neither door ever reopens. That is
    /// essentially every real-world Swift package with external dependencies.
    ///
    /// `swift package resolve` is used rather than a full build -- verified to
    /// write `Package.resolved` (rc 0) without compiling anything, so `init`
    /// does not pay a cold release build to learn this.
    ///
    /// THE EDGE CASE THAT MUST KEEP WORKING: a package with no external
    /// dependencies. SwiftPM writes no lockfile for one, not on `resolve` and
    /// not on `swift build -c release` (both verified, rc 0, no file), so
    /// `probe` answers `.notProduced` and this returns having changed nothing
    /// at all. Nothing here refuses such a package, and `BaselineRunner`
    /// records `Lockfile.absentPin` for it.
    ///
    /// Not `private`: exercised directly by `InitRunnerTests`, the same way
    /// `ensureGitignoreCoversBuildOutput` is, so the git behaviour can be
    /// bound without a full `run()` (which needs a real benchmark package and
    /// therefore the network).
    @discardableResult
    static func ensureLockfileTracked(repo: URL) throws -> HarnessCommit? {
        let requirement = try resolveLockfile(repo: repo)
        return try commitHarnessPrerequisites(repo: repo, paths: requirement.pathsToTrack)
    }

    /// Whether this package needs a lockfile tracked, and therefore which paths
    /// `init`'s one commit has to cover.
    enum LockfileRequirement: Equatable, Sendable {
        case required
        case notProduced

        /// `.gitignore` is in both cases because `init` writes it either way
        /// and it has to be tracked before `baseline` freezes: `.build/` must
        /// be ignored AT `frozenCommit`, or the pinned worktree's `clean -fd`
        /// deletes the warm build cache on every eval.
        var pathsToTrack: [String] {
            self == .required ? [Lockfile.name, ".gitignore"] : [".gitignore"]
        }
    }

    /// The probe and every refusal that depends on it -- and NOTHING that
    /// writes into the repository's tracked files or git history.
    ///
    /// Split out from the commit half in round 2 so `run` can call it BEFORE
    /// `config.yaml`, `program.md` and `.gitignore` exist. Both refusals it
    /// raises say "refusing to configure this repository", which was false
    /// when this ran last: the repository had already been configured on disk.
    /// Now nothing has been written when either fires.
    ///
    /// `Lockfile.probe` does write -- `Package.resolved` and `.build/` -- but
    /// those are SwiftPM's own artefacts, idempotent, and `.build/` was already
    /// created by the `swift package describe` that runs before this. Neither
    /// is part of the "either every file this tool writes appears, or none
    /// does" guarantee the ordering exists to protect.
    static func resolveLockfile(repo: URL) throws -> LockfileRequirement {
        switch Lockfile.probe(in: repo) {
        case .undetermined(let why):
            throw InitError.dependencyResolveFailed(why)
        case .notProduced:
            // No external dependencies anywhere in the graph. SwiftPM has said
            // so itself; there is no lockfile to track and never will be.
            return .notProduced
        case .required:
            break
        }

        // An ignore rule over the lockfile is fatal, whether or not the file
        // is currently tracked: it is the exact remedy `doctor` used to
        // recommend, and it silently un-pins every dependency.
        if Lockfile.isGitIgnored(repo: repo) == true {
            throw InitError.lockfileGitIgnored
        }

        // `isTracked` returns nil when this is not a git repository at all.
        // `init` still does useful work there (config, program.md,
        // .gitignore), and there is nothing to commit into; `baseline`
        // requires git and refuses an unpinned dependency set on its own, so
        // the guarantee is not lost, only deferred to the command that can
        // actually enforce it.
        if Lockfile.isTracked(repo: repo) == true,
           try isModified(repo: repo, path: Lockfile.name) {
            // resolve rewrote a lockfile that was already committed: the
            // manifest and the pins disagree. That is a dependency change, and
            // init does not make one silently.
            throw InitError.lockfileOutOfDate
        }
        return .required
    }

    /// Commits whichever of `paths` git currently reports as untracked or
    /// modified, as ONE commit, staging BY PATH.
    ///
    /// Never `git add -A`: `init` runs in a repository whose other
    /// uncommitted work is none of its business, and sweeping that into a
    /// harness-setup commit would be both surprising and, once `baseline`
    /// freezes the result, unrecoverable without rewriting history.
    ///
    /// A no-op when nothing needs committing -- which also keeps `git commit`
    /// from failing with "nothing to commit" and turning a clean re-run of
    /// `init --force` into an error.
    /// Returns what it committed, so `InitCommand` can ANNOUNCE it. `nil` means
    /// nothing needed committing.
    @discardableResult
    private static func commitHarnessPrerequisites(repo: URL, paths: [String]) throws -> HarnessCommit? {
        let git = Git(repo: repo)
        guard (try? git.run(["rev-parse", "--git-dir"])) != nil else { return nil }

        var pending: [String] = []
        for path in paths {
            guard FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(path).path) else { continue }
            if (try? isModified(repo: repo, path: path)) == true { pending.append(path) }
        }
        guard !pending.isEmpty else { return nil }

        do {
            try git.run(["add", "--"] + pending)
            try git.run(["commit", "-q", "-m",
                         "chore: track \(pending.joined(separator: " and ")) for autor3search-swift",
                         "--"] + pending)
            return HarnessCommit(sha: try git.head(), paths: pending)
        } catch {
            throw InitError.prerequisiteCommitFailed("\(error)")
        }
    }

    /// Whether git reports any change for `path` -- untracked, modified, or
    /// staged. `git status --porcelain -- <path>` prints one line per changed
    /// path and nothing at all for a clean, tracked file, which is exactly the
    /// three-way distinction needed here in a single call.
    private static func isModified(repo: URL, path: String) throws -> Bool {
        try !Git(repo: repo).run(["status", "--porcelain", "--", path]).isEmpty
    }

    /// Idempotently ensures `.gitignore` covers every file this tool writes
    /// inside the repository under test. Keyed on a marker comment rather than a raw
    /// substring match, so a re-run of `init` (with `--force`) never appends a
    /// duplicate MARKER LINE, whether `.gitignore` did not exist, already existed
    /// without this entry, or already has it from a previous `init` -- but see the
    /// UPGRADE note below: the marker being present no longer means every entry is,
    /// so this now checks each entry independently even when the marker is found.
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
    ///
    /// UPGRADE, NOT JUST FIRST-WRITE. A repository initialised before Task 20 has
    /// `.gitignore` with the marker AND the original three entries, but NOT
    /// `.autor3search/profiles/` — and the original version of this function
    /// returned immediately the moment it saw the marker, which left every
    /// already-initialised repository (including a re-`init --force`, since the
    /// marker survives that too) permanently on whatever entry set existed the day
    /// it was first initialised. That is the exact bug this whole function exists
    /// to prevent, reached through its own upgrade path: `profile` followed by
    /// `git add -A` would still commit the raw sample files on any repo `init`'d
    /// before this entry was added, and `eval`'s scope gate would still reject it.
    /// So: when the marker is present, this no longer returns early -- it checks
    /// each required entry as its own line and appends only whatever is missing,
    /// leaving the rest of the file (including whatever the human added below the
    /// marker) untouched. A repository that already has every entry is left
    /// byte-for-byte unchanged, which is what keeps this idempotent.
    private static let gitignoreMarker = "# autor3search-swift"
    private static let requiredGitignoreEntries = [
        ".build/", "results.tsv", "run.log", ".autor3search/profiles/",
    ]

    /// Not `private`: exercised directly by `InitRunnerTests` so idempotence can be
    /// verified without a full, toolchain-and-possibly-network-dependent `run()`.
    static func ensureGitignoreCoversBuildOutput(repo: URL) throws {
        let url = repo.appendingPathComponent(".gitignore")
        let entries = requiredGitignoreEntries

        guard FileManager.default.fileExists(atPath: url.path) else {
            let block = ([gitignoreMarker] + entries).joined(separator: "\n") + "\n"
            try block.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let existing = try String(contentsOf: url, encoding: .utf8)
        let existingLines = Set(existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))

        // Whatever is genuinely missing, whether the marker is present (an
        // UPGRADE: this repo was `init`'d before some of these entries existed)
        // or absent entirely (a `.gitignore` this tool has never touched).
        var missing = entries.filter { !existingLines.contains($0) }
        if !existingLines.contains(gitignoreMarker) {
            missing = [gitignoreMarker] + missing
        }
        guard !missing.isEmpty else { return }  // Every entry already present: untouched, byte-for-byte.

        let needsNewline = !existing.isEmpty && !existing.hasSuffix("\n")
        let updated = existing + (needsNewline ? "\n" : "") + (existing.isEmpty ? "" : "\n") +
            missing.joined(separator: "\n") + "\n"
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}
