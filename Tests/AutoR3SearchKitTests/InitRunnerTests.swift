import Testing
import Foundation
@testable import AutoR3SearchKit

@Test func discoversBenchmarkNamesFromBenchmarkSource() {
    let src = """
    import Benchmark
    nonisolated(unsafe) let benchmarks = {
      Benchmark("ParseJSON") { b in }
      Benchmark("EncodeUTF8", configuration: .init(maxIterations: 200)) { b in }
    }
    """
    #expect(InitRunner.discoverBenchmarks(benchmarkSource: src) == ["ParseJSON", "EncodeUTF8"])
}

@Test func ignoresBenchmarkMentionsInComments() {
    let src = """
    // Benchmark("NotReal") { b in }
    Benchmark("Real") { b in }
    """
    #expect(InitRunner.discoverBenchmarks(benchmarkSource: src) == ["Real"])
}

@Test func refusesToWriteAConfigWithNoBenchmarks() {
    // The tool optimizes what it can measure, and refuses to pretend otherwise.
    #expect(throws: InitError.self) { try InitRunner.validateDiscovered([]) }
}

@Test func theRefusalTellsTheHumanWhatToDo() {
    do {
        try InitRunner.validateDiscovered([])
        Issue.record("expected a refusal")
    } catch let e as InitError {
        let m = String(describing: e)
        #expect(m.contains("Benchmark("))
        #expect(m.contains("ordo-one/benchmark"), "must cite the current package URL, not the renamed-away one")
        #expect(m.contains("cold path") || m.contains("bottleneck"))
    } catch { Issue.record("wrong error type") }
}

@Test func programMDUsesTheCurrentPackageURLAndWorkingIdiom() {
    let c = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench",
                   benchmarks: ["A"], count: 10, alpha: 0.05, minEffectPct: 1.0,
                   maxRegressPct: 5.0, timeoutSeconds: 600)
    let md = ProgramMD.render(config: c, tag: "sep16")
    #expect(md.contains("ordo-one/benchmark"))
    #expect(!md.contains("ordo-one/package-benchmark"))
    #expect(md.contains("nonisolated(unsafe) let benchmarks"),
            "the plain form does not compile under Swift 6 language mode")
    #expect(md.contains("git reset --hard HEAD~1"))
    #expect(md.contains("autor3search-swift/sep16"))
}

// MARK: - Fix round 1: a concatenated literal must be skipped, not truncated
//
// Truncating `Benchmark("A" + "B")` to `"A"` produces a plausible WRONG name:
// `validateDiscovered` passes (the list is non-empty), `init` succeeds, and it writes
// `benchmarks: ["A"]` for a benchmark actually registered as `"AB"`. At measurement
// time a `--filter '^A$'` match against the real `BenchmarkTool` finds nothing, which
// (verified against the real tool) exits 0 with no percentile table — a confusing
// `noPercentileTable` failure caused by a config `init` itself generated. Skipping
// entirely, so a source file containing ONLY a concatenated name routes to the
// well-tested `noBenchmarks` refusal with its full explanatory text, is the correct
// outcome and matches this scanner's existing philosophy for interpolation.

@Test func concatenatedLiteralNamesAreSkippedNotTruncated() {
    let src = #"""
    import Benchmark
    nonisolated(unsafe) let benchmarks = {
      Benchmark("A" + "B") { b in }
    }
    """#
    #expect(InitRunner.discoverBenchmarks(benchmarkSource: src).isEmpty)
}

@Test func aFileOfOnlyConcatenatedNamesRoutesToNoBenchmarks() throws {
    let src = #"""
    import Benchmark
    nonisolated(unsafe) let benchmarks = {
      Benchmark("A" + "B") { b in }
      Benchmark("A" + suffix) { b in }
    }
    """#
    let names = InitRunner.discoverBenchmarks(benchmarkSource: src)
    #expect(names.isEmpty)
    #expect(throws: InitError.self) { try InitRunner.validateDiscovered(names) }
    do {
        try InitRunner.validateDiscovered(names)
    } catch let e as InitError {
        guard case .noBenchmarks = e else {
            Issue.record("wrong InitError case: \(e)")
            return
        }
    } catch {
        Issue.record("wrong error type")
    }
}

// MARK: - Extra coverage beyond the brief's five required tests
//
// The five tests above are verbatim from the brief and must not be weakened.
// Everything below exercises `InitRunner.run` end to end: multiple benchmark
// targets, the --force/no-overwrite behaviour, scope derivation that excludes
// benchmark-adjacent directories, and .gitignore idempotence.

/// Removes `urls` when `body` returns OR throws, via `defer`. Same pattern as
/// `withTempDirectories` in GitTests.swift (private there, so duplicated here
/// per that file's own note on VerdictJSONTests doing the same).
private func withTempDirectories<T>(_ urls: URL..., body: () throws -> T) rethrows -> T {
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
    return try body()
}

private func tempDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// Fabricates a `PackageDescription` directly (bypassing `swift package
/// describe`, which needs a real toolchain invocation, and for a package with
/// external dependencies, network access) to exercise `deriveScope` and the
/// multi-target refusal path quickly and deterministically. A live,
/// toolchain-invoking end-to-end run is exercised separately (see the written
/// report) against a real package carrying `ordo-one/benchmark`.
private func target(_ name: String, type: String = "library", path: String, productDependencies: [String] = []) -> SwiftTarget {
    SwiftTarget(name: name, type: type, path: path, productDependencies: productDependencies)
}

@Test func deriveScopeExcludesTestsAndBenchmarksButKeepsLibraryTargets() {
    let description = PackageDescription(targets: [
        target("Lib", path: "Sources/Lib"),
        target("LibTests", type: "test", path: "Tests/LibTests"),
        target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
        target("Fixtures", type: "library", path: "Benchmarks/Fixtures"),
    ])
    let scope = InitRunner.deriveScope(from: description)
    // The library target is in scope...
    #expect(scope.contains("Sources/Lib/**"))
    // ...but the benchmark HELPER target (fixture data the benchmark consumes,
    // holding no Benchmark product dependency itself) must NOT be in scope:
    // it sits outside the frozen set, so scope is the only thing stopping an
    // agent shrinking the benchmark's real workload by editing it.
    #expect(!scope.contains(where: { $0.hasPrefix("Benchmarks/") }))
    #expect(scope != ["**"])
}

// MARK: - Fix round 1: parsing the target-dependency graph out of `swift package
// describe --type json`'s output (still used in round 2 — see below — just no
// longer to make an automatic scope decision).

private func describeJSON(targets: [(name: String, path: String, type: String, productDependencies: [String], targetDependencies: [String])]) -> Data {
    let targetsJSON = targets.map {
        """
        {
          "name": "\($0.name)",
          "path": "\($0.path)",
          "type": "\($0.type)",
          "product_dependencies": [\($0.productDependencies.map { "\"\($0)\"" }.joined(separator: ", "))],
          "target_dependencies": [\($0.targetDependencies.map { "\"\($0)\"" }.joined(separator: ", "))]
        }
        """
    }.joined(separator: ",\n")
    return Data("""
    { "targets": [ \(targetsJSON) ] }
    """.utf8)
}

@Test func parseTargetDependencyPathsResolvesNamesToPaths() throws {
    let json = describeJSON(targets: [
        (name: "Lib", path: "Sources/Lib", type: "library", productDependencies: [], targetDependencies: []),
        (name: "BenchFixtures", path: "Sources/BenchFixtures", type: "library", productDependencies: [], targetDependencies: []),
        (name: "Bench", path: "Benchmarks/Bench", type: "executable",
         productDependencies: ["Benchmark"], targetDependencies: ["Lib", "BenchFixtures"]),
    ])
    let paths = try InitRunner.parseTargetDependencyPaths(json, of: "Bench")
    #expect(paths == ["Sources/Lib", "Sources/BenchFixtures"])
}

// MARK: - Fix round 2: deriveScope no longer guesses which dependency is a fixture
//
// Round 1's "greedy, floor of one" exclusion was alphabetical luck, not a signal.
// `Sources/BenchFixtures` sorts before `Sources/Lib`, so the fixture happened to be
// excluded and the real library happened to survive. Rename the exact same two roles
// `Sources/Alpha` (real library) and `Sources/ZHelper` (fixture) and the sort order
// flips: the real library would have been excluded and the fixture left in scope —
// silently, which is the one outcome this project never accepts. `deriveScope` no
// longer reads the dependency graph at all; it only ever applies path adjacency.
// `target_dependencies` is still read (via `parseTargetDependencyPaths` /
// `benchmarkHelperPaths(of:repo:)`, unchanged from round 1) but now purely to power
// `scopedBenchmarkDependencyPaths` / `dependencyScopeWarning`, a WARNING surfaced
// after `init` succeeds rather than a decision made silently on the human's behalf.

/// The counterexample from the round-2 review: `Sources/Alpha` (the real library)
/// and `Sources/ZHelper` (the fixture) are both direct dependencies of the benchmark.
/// Under the deleted greedy logic this excluded Alpha and kept ZHelper — the worst
/// possible outcome. Now neither is guessed at: both stay in scope, and the warning
/// names BOTH of them, because `init` genuinely cannot tell them apart.
@Test func doesNotGuessWhichDependencyIsAFixtureAndWarnsAboutBothCandidates() {
    let description = PackageDescription(targets: [
        target("Alpha", path: "Sources/Alpha"),
        target("ZHelper", path: "Sources/ZHelper"),
        target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
    ])
    let scope = InitRunner.deriveScope(from: description)
    #expect(scope.contains("Sources/Alpha/**"), "no signal distinguishes it from a fixture; must not be silently excluded")
    #expect(scope.contains("Sources/ZHelper/**"), "no signal distinguishes it from the real library; must not be silently kept without warning")

    let helperPaths: Set<String> = ["Sources/Alpha", "Sources/ZHelper"]
    let warnedPaths = InitRunner.scopedBenchmarkDependencyPaths(scope: scope, benchmarkHelperPaths: helperPaths)
    #expect(Set(warnedPaths) == ["Sources/Alpha", "Sources/ZHelper"])

    let warning = InitRunner.dependencyScopeWarning(paths: warnedPaths)
    #expect(warning != nil)
    #expect(warning!.contains("Sources/Alpha"), "must name the real library too: init cannot tell it apart from a fixture")
    #expect(warning!.contains("Sources/ZHelper"))
    #expect(warning!.contains("baseline"), "must mention that baseline freezes the config hash, or the warning gives no deadline")
}

/// The SAME shape as the counterexample above, but with the favourable naming from
/// round 1's test (`BenchFixtures` sorts before `Lib`) — the ordering under which the
/// deleted greedy logic happened to produce the "right" answer by luck. Both orderings
/// must now produce the identical, non-guessing result: nothing excluded by the graph
/// signal, both targets present, in both cases. Asserting the two scopes have the same
/// SHAPE (both candidates kept, neither excluded) is the order-independence property;
/// the literal path strings necessarily differ since the targets are named differently.
@Test func favourableAndUnfavourableNamingOrdersNowProduceTheSameNonGuessingResult() {
    func scopeKeepsBothDependencies(libraryPath: String, fixturePath: String) -> Bool {
        let description = PackageDescription(targets: [
            target("Library", path: libraryPath),
            target("Fixture", path: fixturePath),
            target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
        ])
        let scope = InitRunner.deriveScope(from: description)
        return scope.contains("\(libraryPath)/**") && scope.contains("\(fixturePath)/**") && scope.count == 2
    }

    // Favourable order: fixture path sorts BEFORE the library path.
    let favourable = scopeKeepsBothDependencies(libraryPath: "Sources/Lib", fixturePath: "Sources/BenchFixtures")
    // Unfavourable order: fixture path sorts AFTER the library path (the round-2
    // counterexample's ordering).
    let unfavourable = scopeKeepsBothDependencies(libraryPath: "Sources/Alpha", fixturePath: "Sources/ZHelper")

    #expect(favourable, "favourable ordering must keep both dependencies in scope")
    #expect(unfavourable, "unfavourable ordering must ALSO keep both dependencies in scope")
    #expect(favourable == unfavourable, "both orderings must produce the identical (non-guessing) outcome")
}

/// A helper that IS path-adjacent to the benchmark (e.g. `Benchmarks/Fixtures`,
/// sibling to `Benchmarks/Bench`) is still excluded automatically — path adjacency is
/// a real signal and still applies. And because it was never in scope to begin with,
/// it must not appear in the dependency warning either: the warning is about targets
/// the agent can actually edit, and this one it cannot.
@Test func pathAdjacentHelperStaysExcludedAndNeverAppearsInTheWarning() {
    let description = PackageDescription(targets: [
        target("Lib", path: "Sources/Lib"),
        target("Fixtures", path: "Benchmarks/Fixtures"),
        target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
    ])
    let scope = InitRunner.deriveScope(from: description)
    #expect(scope.contains("Sources/Lib/**"))
    #expect(!scope.contains(where: { $0.hasPrefix("Benchmarks/") }), "path-adjacent helper must still be excluded automatically")

    // Even though it is (hypothetically) ALSO a declared target dependency of the
    // benchmark, it must not appear in the warning, because it is not in scope.
    let helperPaths: Set<String> = ["Sources/Lib", "Benchmarks/Fixtures"]
    let warnedPaths = InitRunner.scopedBenchmarkDependencyPaths(scope: scope, benchmarkHelperPaths: helperPaths)
    #expect(!warnedPaths.contains("Benchmarks/Fixtures"), "a target that is not in scope has nothing to warn about")
    #expect(warnedPaths.contains("Sources/Lib"))
}

@Test func selectBenchmarkTargetRefusesToPickAmongSeveral() {
    let description = PackageDescription(targets: [
        target("Lib", path: "Sources/Lib"),
        target("BenchA", type: "executable", path: "Benchmarks/A", productDependencies: ["Benchmark"]),
        target("BenchB", type: "executable", path: "Benchmarks/B", productDependencies: ["Benchmark"]),
    ])
    do {
        _ = try InitRunner.selectBenchmarkTarget(from: description)
        Issue.record("expected a refusal: two benchmark targets, neither chosen silently")
    } catch let e as InitError {
        guard case .multipleBenchmarkTargets(let names) = e else {
            Issue.record("wrong InitError case: \(e)")
            return
        }
        #expect(Set(names) == ["BenchA", "BenchB"])
        #expect(String(describing: e).contains("BenchA"))
        #expect(String(describing: e).contains("BenchB"))
    } catch {
        Issue.record("wrong error type")
    }
}

@Test func selectBenchmarkTargetPicksTheOnlyOne() throws {
    let description = PackageDescription(targets: [
        target("Lib", path: "Sources/Lib"),
        target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
    ])
    let picked = try InitRunner.selectBenchmarkTarget(from: description)
    #expect(picked.name == "Bench")
}

@Test func runRefusesToOverwriteWithoutForce() throws {
    let dir = tempDir()
    try withTempDirectories(dir) {
        try write("version: 1\n", to: dir.appendingPathComponent(".autor3search/config.yaml"))
        #expect(throws: InitError.self) { try InitRunner.run(repo: dir, force: false) }
    }
}

/// `run()` writes `config.serialized()` straight to disk; if that emitted form
/// weren't loadable by `Config.load`, every consumer downstream of `init` (baseline,
/// eval, the scope gate reading config.yaml at Task 17) would break on the very
/// first file `init` ever produces. Verified live against a real toolchain in the
/// written report too (a real ordo-one/benchmark package, end to end); this is the
/// fast, hermetic version of that same guarantee.
@Test func serializedConfigRoundTripsThroughLoad() throws {
    let c = Config(version: 1, scope: ["Sources/Lib/**"], benchmarkTarget: "Bench",
                   benchmarks: ["SlowJoin"], count: 10, alpha: 0.05, minEffectPct: 1.0,
                   maxRegressPct: 5.0, timeoutSeconds: 600)
    let dir = tempDir()
    try withTempDirectories(dir) {
        let url = dir.appendingPathComponent("config.yaml")
        try write(try c.serialized(), to: url)
        let loaded = try Config.load(url)
        #expect(loaded == c)
        try loaded.validate()
    }
}

@Test func gitignoreIsCreatedWhenAbsent() throws {
    let dir = tempDir()
    try withTempDirectories(dir) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let text = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(text.contains(".build/"))
    }
}

@Test func gitignoreAppendsWhenMissingFromAnExistingFile() throws {
    let dir = tempDir()
    try withTempDirectories(dir) {
        try write("*.log\n", to: dir.appendingPathComponent(".gitignore"))
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let text = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(text.contains("*.log"), "existing entries must survive")
        #expect(text.contains(".build/"))
    }
}

@Test func gitignoreCoversEveryFileTheHarnessWritesIntoTheRepository() throws {
    // Not cosmetic, and not only .build/. `eval` appends to results.tsv on every
    // experiment, so from the second experiment onward it is an untracked file in the
    // repository; an agent committing with `git add -A` sweeps it into its commit, and
    // eval's own scope gate -- which diffs the commit against frozenCommit -- then
    // rejects that commit as out_of_scope for a file eval itself wrote. Every experiment
    // after the first would fail. spec.md 9 lists both results.tsv and run.log as
    // gitignored by init.
    let dir = tempDir()
    try withTempDirectories(dir) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let text = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains(".build/"))
        #expect(lines.contains("results.tsv"), "eval writes results.tsv into the repository under test")
        #expect(lines.contains("run.log"), "run.log is the other in-repository harness output")
        let profilesReason = "profile (Task 20) writes each benchmark's raw sampler output " +
            "under .autor3search/profiles/, inside the same directory config.yaml is tracked " +
            "in; without this entry a profiling run followed by git add -A commits it"
        #expect(lines.contains(".autor3search/profiles/"), "\(profilesReason)")
    }
}

@Test func gitignoreUpgradesAnAlreadyInitialisedRepoMissingANewerEntry() throws {
    // Reproduces the round-1 regression directly: a repo `init`'d BEFORE Task 20
    // added `.autor3search/profiles/` has the marker and the original three
    // entries, but not the fourth. The old implementation returned the instant it
    // saw the marker, so this repo -- and every repo `init`'d before this task,
    // `init --force` included, since the marker survives that too -- stayed on
    // the stale three-entry set forever. `profile` followed by `git add -A`
    // would then commit the raw sample files, and eval's scope gate would reject
    // the commit as out_of_scope for a file the harness itself wrote.
    let dir = tempDir()
    try withTempDirectories(dir) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("# autor3search-swift\n.build/\nresults.tsv\nrun.log\n",
                  to: dir.appendingPathComponent(".gitignore"))
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let text = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains(".autor3search/profiles/"),
                "an already-initialised repo must be upgraded, not left on its original entry set")
        #expect(lines.contains(".build/"), "pre-existing entries must survive the upgrade")
        #expect(lines.contains("results.tsv"), "pre-existing entries must survive the upgrade")
        #expect(lines.contains("run.log"), "pre-existing entries must survive the upgrade")
        #expect(text.components(separatedBy: "# autor3search-swift").count == 2,
                "the marker must still appear exactly once after an upgrade")

        // A second call against the now-upgraded file changes nothing further.
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let second = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(text == second, "a repo with every entry already present must be left byte-for-byte unchanged")
    }
}

@Test func gitignoreIsIdempotentAcrossRepeatedCalls() throws {
    let dir = tempDir()
    try withTempDirectories(dir) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let first = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        try InitRunner.ensureGitignoreCoversBuildOutput(repo: dir)
        let second = try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(first == second, "repeated calls must not duplicate the entry")
        #expect(second.components(separatedBy: "# autor3search-swift").count == 2,
                "the marker must appear exactly once")
    }
}

// =========================================================================
// MARK: - The dependency lockfile
// =========================================================================
//
// `init` must leave a repository with dependencies holding a COMMITTED
// Package.resolved, before `baseline` freezes anything. `swift package
// describe` -- all init used to run -- exits 0 and writes no lockfile;
// `swift build` writes one into the package root. So the first `eval`'s own
// build created the file and every experiment after it failed permanently:
// manifest_change_rejected if the agent committed it, dirty_working_tree if it
// did not, forever, because gate 1 diffs frozenCommit..HEAD and frozenCommit
// never advances.

/// THE FIX. A package with a real source-control dependency and no lockfile
/// must come out of `init` with `Package.resolved` created AND committed.
@Test func initResolvesAndCommitsTheLockfileForAPackageWithDependencies() throws {
    let (root, repo) = try makeDependentGitFixture()
    try withTempDirectories(root) {
        let lockfile = repo.appendingPathComponent("Package.resolved")
        #expect(!FileManager.default.fileExists(atPath: lockfile.path),
                "the fixture must start with no lockfile")

        try InitRunner.ensureLockfileTracked(repo: repo)

        #expect(FileManager.default.fileExists(atPath: lockfile.path),
                "swift package resolve must have written the lockfile")
        #expect(Lockfile.isTracked(repo: repo) == true, "the lockfile must be tracked")
        let git = Git(repo: repo)
        #expect(try git.isClean(), "init must leave no uncommitted lockfile behind")
        // Committed, not merely staged: baseline freezes a COMMIT.
        let atHead = try git.run(["ls-tree", "--name-only", "HEAD", "--", "Package.resolved"])
        #expect(atHead == "Package.resolved", "the lockfile must exist at HEAD, got \"\(atHead)\"")
    }
}

/// THE EDGE CASE THAT MUST KEEP WORKING. A package with no external
/// dependencies has no lockfile and SwiftPM never creates one (verified:
/// `swift package resolve` and `swift build -c release` both exit 0 and write
/// nothing). `init` must change nothing and must not refuse.
@Test func initLeavesADependencyFreePackageAloneAndDoesNotRefuseIt() throws {
    let (repo, git) = try makeGitFixture()
    try withTempDirectories(repo) {
        let before = try git.head()
        try InitRunner.ensureLockfileTracked(repo: repo)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.resolved").path),
                "SwiftPM must not have invented a lockfile for a package with no dependencies")
        #expect(try git.head() == before, "nothing needed committing, so nothing may be committed")
        #expect(try git.isClean())
    }
}

/// Idempotent: `init --force` on an already-prepared repository commits
/// nothing further. A second commit here would be harmless noise the first
/// time and a "nothing to commit" failure the time after.
@Test func initLockfileHandlingIsIdempotent() throws {
    let (root, repo) = try makeDependentGitFixture()
    try withTempDirectories(root) {
        try InitRunner.ensureLockfileTracked(repo: repo)
        let afterFirst = try Git(repo: repo).head()
        try InitRunner.ensureLockfileTracked(repo: repo)
        #expect(try Git(repo: repo).head() == afterFirst,
                "a second init must not produce a second commit")
    }
}

/// THE SECOND-ORDER HOLE, CLOSED AT THE SOURCE. `doctor` used to advise
/// "commit or .gitignore it". A repository that took the .gitignore branch has
/// `packageResolvedSHA256` pinning the hash of zero bytes forever -- every
/// dependency silently un-pinned, and gate 2 unable to see a dependency
/// change. `init` refuses that state rather than working around it.
@Test func initRefusesAGitignoredLockfile() throws {
    let (root, repo) = try makeDependentGitFixture()
    try withTempDirectories(root) {
        let gitignore = repo.appendingPathComponent(".gitignore")
        try (try String(contentsOf: gitignore, encoding: .utf8) + "Package.resolved\n")
            .write(to: gitignore, atomically: true, encoding: .utf8)
        let commit = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                                        ["-c", "git add -A && git commit -q -m ignore"],
                                        cwd: repo, env: nil, timeout: 60)
        #expect(commit.exitCode == 0, "\(commit.stderr)")

        do {
            try InitRunner.ensureLockfileTracked(repo: repo)
            Issue.record("expected init to refuse a .gitignore'd Package.resolved")
        } catch let error as InitError {
            #expect("\(error)".contains(".gitignore"),
                    "the refusal must point at the ignore rule: \(error)")
        }
    }
}
