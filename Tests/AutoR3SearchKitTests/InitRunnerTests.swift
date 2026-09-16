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

// MARK: - Fix round 1: target-dependency graph as a second scope-exclusion signal
//
// Path adjacency alone misses a benchmark helper that is a DECLARED target
// dependency of the benchmark but lives nowhere near it, e.g. `Sources/BenchFixtures`
// alongside a real library at `Sources/Lib` and a benchmark at `Benchmarks/Bench` —
// `Sources/BenchFixtures` never nests under `Benchmarks`, so the path rule alone
// cannot catch it. `swift package describe --type json` reports this as
// `"target_dependencies": ["BenchFixtures"]` on the benchmark target's own JSON
// object; `parseTargetDependencyPaths` decodes exactly that field, independent of
// Task 8's frozen `PackageDescribe`/`SwiftTarget`.

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

/// The exact layout the round-1 review specified: benchmarks in a separate
/// top-level directory (`Benchmarks/Bench`), a helper under `Sources/`
/// (`Sources/BenchFixtures`) declared as a target dependency of the benchmark, and a
/// REAL library also present (`Sources/Lib`). The helper must be excluded from
/// scope; the real library must not be — this is the case
/// `deriveScopeExcludesTestsAndBenchmarksButKeepsLibraryTargets` does not cover
/// (that test's helper is path-adjacent; this one only shows up in the dependency
/// graph).
@Test func deriveScopeExcludesAGraphOnlyHelperUnderSourcesButKeepsTheRealLibrary() {
    let description = PackageDescription(targets: [
        target("Lib", path: "Sources/Lib"),
        target("BenchFixtures", path: "Sources/BenchFixtures"),
        target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
    ])
    let scope = InitRunner.deriveScope(from: description, benchmarkHelperPaths: ["Sources/BenchFixtures"])
    #expect(scope.contains("Sources/Lib/**"), "the real library must stay in scope")
    #expect(!scope.contains("Sources/BenchFixtures/**"), "the graph-declared helper must be excluded")
    #expect(!scope.contains(where: { $0.hasPrefix("Benchmarks/") }))
}

/// Regression test for the exact failure mode caught during this fix: a benchmark's
/// SOLE non-test, non-benchmark dependency is very often the actual library under
/// test (verified against a real, working single-library-single-benchmark package —
/// see the report). Unconditionally excluding every graph-declared dependency would
/// drive `scope` to empty for this — the single most common package shape — turning
/// `init` into a hard refusal rather than a per-edit `out_of_scope` rejection.
/// `deriveScope` must back the graph signal out when applying it would empty scope.
@Test func deriveScopeDoesNotEmptyItselfWhenTheOnlyDependencyIsTheRealLibrary() {
    let description = PackageDescription(targets: [
        target("Lib", path: "Sources/Lib"),
        target("Bench", type: "executable", path: "Benchmarks/Bench", productDependencies: ["Benchmark"]),
    ])
    // As if `parseTargetDependencyPaths` reported Bench's only dependency, "Lib", as
    // a helper — the worst case for the graph signal.
    let scope = InitRunner.deriveScope(from: description, benchmarkHelperPaths: ["Sources/Lib"])
    #expect(scope == ["Sources/Lib/**"], "must fall back rather than leave scope empty")
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
