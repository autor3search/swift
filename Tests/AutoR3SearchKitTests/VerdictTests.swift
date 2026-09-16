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

// --- Fix round 1 additions below. The nine tests above are byte-identical to
// the task-13 brief and must stay that way; nothing above this line changed. ---

@Test func regressionGuardCatchesAMarginalRegressionThatBonferroniWouldMiss() {
    // Same scenario as the docs/run-log.md Task 13 mutation-evidence entry: A
    // wins big and cleanly; B regresses ~7.1% in median (above the 5%
    // maxRegressPct guard) with p = 0.04325705254497824 - significant at the
    // uncorrected alpha (0.05) but NOT at the Bonferroni-corrected alpha for
    // k=2 (0.025). A regression guard that used the corrected alpha instead
    // of the uncorrected one (regressionAlpha returning alpha/k) would find
    // B's p is not below 0.025, never fire, and this run would come back
    // .keep instead of the significant_regression discard it must produce.
    let aBase = (0..<10).map { 100.0 + Double($0) * 0.01 }
    let aCand = (0..<10).map { 50.0 + Double($0) * 0.01 }
    let bBaseNoise: [Double] = [-8, 6, -3, 9, -5, 2, -9, 7, 0, -4]
    let bCandNoise: [Double] = [5, -7, 3, -9, 8, -2, 9, -6, 1, -3]
    let bBase = bBaseNoise.map { 100.0 + $0 }
    let bCand = bCandNoise.map { 100.0 * 1.06 + $0 }

    let v = Scoring.decide(samples: [samples("A", base: aBase, cand: aCand),
                                     samples("B", base: bBase, cand: bCand)],
                           config: cfg(benchmarks: ["A", "B"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .discard)
    #expect(v.reason == "significant_regression")
}

@Test func rule2RequiresTheCorrectedAlphaNotJustTheUncorrectedOne() {
    // Two benchmarks. "Win" is a real improvement whose p = 0.04325705254497824
    // is significant at the uncorrected alpha (0.05) but NOT at the
    // Bonferroni-corrected alpha for k=2 (0.025) - the mirror image of the
    // regression scenario above, same |p|, opposite direction. "Neutral" is
    // pure noise, significant at neither. If rule 2 checked p < config.alpha
    // instead of the corrected threshold, "Win" alone would count as a
    // significant win and this run would wrongly come back .keep.
    let winBaseNoise: [Double] = [-8, 6, -3, 9, -5, 2, -9, 7, 0, -4]
    let winCandNoise: [Double] = [5, -7, 3, -9, 8, -2, 9, -6, 1, -3]
    let winCand = winBaseNoise.map { 100.0 + $0 }
    let winBase = winCandNoise.map { 100.0 * 1.06 + $0 }
    let neutralBase = [100.0, 101, 99, 100.5, 99.5, 100.2, 99.8, 100.1, 99.9, 100.3]
    let neutralCand = [100.1, 100.9, 99.2, 100.4, 99.6, 100.0, 99.7, 100.2, 100.0, 99.95]

    let v = Scoring.decide(samples: [samples("Win", base: winBase, cand: winCand),
                                     samples("Neutral", base: neutralBase, cand: neutralCand)],
                           config: cfg(benchmarks: ["Win", "Neutral"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .discard)
    #expect(v.reason == "no_significant_improvement")
}

@Test func correctionUsesTheMeasuredBenchmarkCountNotTheDeclaredOne() {
    // config declares four benchmarks (A, B, C, D) but only two are actually
    // measured (A, B) in this call. A is a real win with p = 0.023230639...,
    // which sits strictly between alpha/4 = 0.0125 (declared count) and
    // alpha/2 = 0.025 (measured count): significant at the measured
    // correction, not at the declared one. B is pure noise, significant at
    // neither. The correct behaviour corrects by what was actually compared
    // (k = samples.count = 2) and KEEPs. If k were taken from
    // config.benchmarks.count (4) instead, A would not clear alpha/4 and
    // this would wrongly discard as no_significant_improvement.
    let aBaseNoise: [Double] = [-8, 6, -3, 9, -5, 2, -9, 7, 0, -4]
    let aCandNoise: [Double] = [5, -7, 3, -9, 8, -2, 9, -6, 1, -3]
    let aCand = aBaseNoise.map { 100.0 + $0 }
    let aBase = aCandNoise.map { 100.0 * 1.07 + $0 }
    let bBase = [100.0, 101, 99, 100.5, 99.5, 100.2, 99.8, 100.1, 99.9, 100.3]
    let bCand = [100.1, 100.9, 99.2, 100.4, 99.6, 100.0, 99.7, 100.2, 100.0, 99.95]

    let v = Scoring.decide(samples: [samples("A", base: aBase, cand: aCand),
                                     samples("B", base: bBase, cand: bCand)],
                           config: cfg(benchmarks: ["A", "B", "C", "D"]), unsafeHits: [], stopRequested: false)
    #expect(v.kind == .keep)
    #expect(v.reason == nil)
}
