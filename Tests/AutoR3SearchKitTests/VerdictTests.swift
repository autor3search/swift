import Testing
@testable import AutoR3SearchKit

private func cfg(count: Int = 10, benchmarks: [String], minEffect: Double = 1.0) -> Config {
    Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench", benchmarks: benchmarks,
           count: count, alpha: 0.05, minEffectPct: minEffect, maxRegressPct: 5.0, timeoutSeconds: 600)
}

private func samples(_ name: String, base: [Double], cand: [Double]) -> BenchmarkSamples {
    BenchmarkSamples(benchmark: name, baseline: base, candidate: cand)
}

@Test func exitCodesFollowTheContract() {
    #expect(VerdictKind.keep.exitCode == 0)
    #expect(VerdictKind.discard.exitCode == 1)
    #expect(VerdictKind.fail.exitCode == 2)
    #expect(VerdictKind.crash.exitCode == 3)
}

@Test func aLargeCleanWinIsKept() {
    let base = Array(repeating: 100.0, count: 10).enumerated().map { 100.0 + Double($0.offset) * 0.1 }
    let cand = Array(repeating: 50.0, count: 10).enumerated().map { 50.0 + Double($0.offset) * 0.1 }
    let v = Scoring.decide(samples: [samples("A", base: base, cand: cand)],
                           config: cfg(benchmarks: ["A"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .keep)
    #expect(v.score < 0.6)
}

@Test func pureNoiseIsDiscardedAsNoSignificantImprovement() {
    let base = [100.0, 101, 99, 100.5, 99.5, 100.2, 99.8, 100.1, 99.9, 100.3]
    let cand = [100.1, 100.9, 99.2, 100.4, 99.6, 100.0, 99.7, 100.2, 100.0, 99.95]
    let v = Scoring.decide(samples: [samples("A", base: base, cand: cand)],
                           config: cfg(benchmarks: ["A"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .discard)
    #expect(v.reason == "no_significant_improvement")
}

@Test func aRealButTinyWinIsDiscardedWithTheOtherReason() {
    // Directionally right, under the floor: different next move for the agent.
    let base = (0..<10).map { 1000.0 + Double($0) * 0.01 }
    let cand = (0..<10).map { 998.0 + Double($0) * 0.01 }   // 0.2% better, clean separation
    let v = Scoring.decide(samples: [samples("A", base: base, cand: cand)],
                           config: cfg(benchmarks: ["A"], minEffect: 1.0),
                           unsafeHits: [], stopRequested: false)
    #expect(v.kind == .discard)
    #expect(v.reason == "improvement_below_min_effect")
}

@Test func aSignificantRegressionBeyondTheGuardRejectsOutright() {
    // A wins big, B regresses badly. Speeding up A by wrecking B is not a win.
    let aBase = (0..<10).map { 100.0 + Double($0) * 0.01 }
    let aCand = (0..<10).map { 40.0 + Double($0) * 0.01 }
    let bBase = (0..<10).map { 100.0 + Double($0) * 0.01 }
    let bCand = (0..<10).map { 150.0 + Double($0) * 0.01 }
    let v = Scoring.decide(samples: [samples("A", base: aBase, cand: aCand),
                                     samples("B", base: bBase, cand: bCand)],
                           config: cfg(benchmarks: ["A", "B"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .discard)
    #expect(v.reason == "significant_regression")
}

@Test func regressionGuardUsesUncorrectedAlpha() {
    // Bonferroni only makes significance harder to declare; applying it to the
    // harm guard would make real regressions easier to miss.
    let v = Scoring.decide(samples: [], config: cfg(benchmarks: ["A"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .discard)   // no data is never a win
    #expect(Scoring.regressionAlpha(config: cfg(benchmarks: ["A","B","C","D"])) == 0.05)
    #expect(Scoring.keepAlpha(config: cfg(benchmarks: ["A","B","C","D"])) == 0.05 / 4)
}

@Test func warnsWhenNoKeepWasReachable() {
    let base = (0..<4).map { 100.0 + Double($0) * 0.01 }
    let cand = (0..<4).map { 50.0 + Double($0) * 0.01 }
    let v = Scoring.decide(samples: [samples("A", base: base, cand: cand),
                                     samples("B", base: base, cand: cand)],
                           config: cfg(count: 4, benchmarks: ["A", "B"]),
                           unsafeHits: [], stopRequested: false)
    #expect(v.warnings.contains { $0.contains("no KEEP is reachable") })
}

@Test func unsafeHitsNeverChangeTheVerdict() {
    let base = (0..<10).map { 100.0 + Double($0) * 0.01 }
    let cand = (0..<10).map { 50.0 + Double($0) * 0.01 }
    let hit = UnsafeHit(file: "A.swift", line: 1, construct: "unsafeBitCast")
    let withHit = Scoring.decide(samples: [samples("A", base: base, cand: cand)],
                                 config: cfg(benchmarks: ["A"]), unsafeHits: [hit], stopRequested: false)
    let without = Scoring.decide(samples: [samples("A", base: base, cand: cand)],
                                 config: cfg(benchmarks: ["A"]), unsafeHits: [], stopRequested: false)
    #expect(withHit.kind == without.kind)
    #expect(withHit.unsafeHits == [hit])
}

@Test func buildConfigurationIsAlwaysReported() {
    let v = Scoring.decide(samples: [], config: cfg(benchmarks: ["A"]), unsafeHits: [], stopRequested: false)
    #expect(v.buildConfiguration == "release")
}
