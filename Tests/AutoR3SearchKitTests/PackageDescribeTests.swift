import Testing
import Foundation
@testable import AutoR3SearchKit

private func fixture() throws -> Data {
    let url = Bundle.module.url(forResource: "describe-sample", withExtension: "json")!
    return try Data(contentsOf: url)
}

@Test func findsTestTargetsIncludingOnesOutsideTests() throws {
    // .testTarget(path:) can put tests anywhere; never assume "Tests/".
    let d = try PackageDescribe.parse(fixture())
    #expect(d.testTargets.map(\.name).sorted() == ["LibTests", "OddTests"])
    #expect(d.testTargets.map(\.path).contains("elsewhere/OddTests"))
}

@Test func identifiesBenchmarkTargetsByProductDependency() throws {
    // Benchmarks are an executableTarget, identified by the Benchmark product.
    let d = try PackageDescribe.parse(fixture())
    #expect(d.benchmarkTargets.map(\.name) == ["Bench"])
}

@Test func frozenDirectoriesCoverTestsAndBenchmarks() throws {
    // The hole from spec.md 2.4: freezing tests alone leaves benchmarks writable,
    // and an agent that can rewrite a benchmark wins every experiment.
    let d = try PackageDescribe.parse(fixture())
    #expect(d.frozenDirectories.sorted() == ["Benchmarks/Bench", "Tests/LibTests", "elsewhere/OddTests"])
}

@Test func plainLibraryTargetsAreNotFrozen() throws {
    let d = try PackageDescribe.parse(fixture())
    #expect(!d.frozenDirectories.contains("Sources/Lib"))
}
