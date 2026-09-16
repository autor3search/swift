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
