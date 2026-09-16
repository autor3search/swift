import Testing
import Foundation
@testable import AutoR3SearchKit

private func cfg(count: Int = 10, benchmarks: [String] = ["A"]) -> Config {
    Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Benchmarks",
           benchmarks: benchmarks, count: count, alpha: 0.05,
           minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
}

@Test func countBelowFourIsRejectedWithAReason() {
    // At n=3 the smallest reachable two-sided p is 0.10; every experiment would
    // DISCARD on a technicality with nothing explaining why.
    #expect(throws: ConfigError.self) { try cfg(count: 3).validate() }
    let message = String(describing: ConfigError.countTooSmall(3))
    #expect(message.contains("4"))
    #expect(message.lowercased().contains("significance") || message.lowercased().contains("reach"))
}

@Test func countOfFourIsAccepted() throws {
    try cfg(count: 4).validate()
}

@Test func emptyBenchmarkListIsRejected() {
    // The tool optimizes what it can measure and refuses to guess.
    #expect(throws: ConfigError.self) { try cfg(benchmarks: []).validate() }
}

@Test func warnsWhenNoKeepIsReachable() {
    // count=4 with 2 benchmarks: alpha/k = 0.025 < floor 0.0286. Unreachable.
    let warning = cfg(count: 4, benchmarks: ["A", "B"]).keepReachabilityWarning()
    #expect(warning != nil)
    #expect(warning!.contains("5"), "must name the count to raise to")
}

@Test func noWarningWhenKeepIsReachable() {
    #expect(cfg(count: 10, benchmarks: ["A", "B", "C"]).keepReachabilityWarning() == nil)
}

@Test func roundTripsThroughYAML() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.yaml")
    try """
    version: 1
    scope:
      - Sources/**
    benchmark_target: Benchmarks
    benchmarks:
      - ParseJSON
    count: 10
    alpha: 0.05
    min_effect_pct: 1.0
    max_regress_pct: 5.0
    timeout_seconds: 600
    """.write(to: url, atomically: true, encoding: .utf8)
    let loaded = try Config.load(url)
    #expect(loaded.benchmarks == ["ParseJSON"])
    #expect(loaded.benchmarkTarget == "Benchmarks")
    #expect(loaded.count == 10)
    try FileManager.default.removeItem(at: dir)
}
