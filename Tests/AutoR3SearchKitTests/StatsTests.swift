import Testing
@testable import AutoR3SearchKit

@Test func binomialKnownValues() {
    #expect(Combinatorics.binomial(6, 3) == 20)
    #expect(Combinatorics.binomial(8, 4) == 70)
    #expect(Combinatorics.binomial(10, 5) == 252)
    #expect(Combinatorics.binomial(12, 6) == 924)
    #expect(Combinatorics.binomial(20, 10) == 184756)
}

@Test func completeSeparationHitsTheFloor() {
    // Disjoint samples give the smallest attainable p: 2/C(2n,n).
    #expect(abs(MannWhitney.twoSidedP([1,2], [3,4]) - 2.0/6.0) < 1e-12)
    #expect(abs(MannWhitney.twoSidedP([1,2,3], [4,5,6]) - 2.0/20.0) < 1e-12)
    #expect(abs(MannWhitney.twoSidedP([1,2,3,4], [5,6,7,8]) - 2.0/70.0) < 1e-12)
}

@Test func interleavedSamplesAreNotSignificant() {
    // A=[1,3,5] B=[2,4,6] gives U=3; P(U<=3)=7/20, two-sided p=0.7.
    #expect(abs(MannWhitney.twoSidedP([1,3,5], [2,4,6]) - 0.7) < 1e-12)
}

@Test func pValueFloorMatchesTheDocumentedTable() {
    #expect(abs(MannWhitney.pValueFloor(roundsPerSide: 4)  - 2.0/70.0)     < 1e-12)
    #expect(abs(MannWhitney.pValueFloor(roundsPerSide: 5)  - 2.0/252.0)    < 1e-12)
    #expect(abs(MannWhitney.pValueFloor(roundsPerSide: 6)  - 2.0/924.0)    < 1e-12)
    #expect(abs(MannWhitney.pValueFloor(roundsPerSide: 10) - 2.0/184756.0) < 1e-15)
}

@Test func reachabilityTableMatchesTheSpec() {
    // spec.md section 7.2. At count=4 with two benchmarks, no KEEP is reachable.
    #expect(MannWhitney.maxBenchmarksWithReachableKeep(roundsPerSide: 4,  alpha: 0.05) == 1)
    #expect(MannWhitney.maxBenchmarksWithReachableKeep(roundsPerSide: 5,  alpha: 0.05) == 6)
    #expect(MannWhitney.maxBenchmarksWithReachableKeep(roundsPerSide: 6,  alpha: 0.05) == 23)
    #expect(MannWhitney.maxBenchmarksWithReachableKeep(roundsPerSide: 10, alpha: 0.05) == 4618)
}

@Test func statisticsNeverMutateTheirInput() {
    // Swift's sort() mutates in place. This bug cost real time in the Go port.
    var a = [5.0, 1.0, 3.0]
    var b = [4.0, 2.0, 6.0]
    let aBefore = a, bBefore = b
    _ = MannWhitney.twoSidedP(a, b)
    _ = Score.medianConfidenceInterval(a, confidence: 0.95)
    _ = Score.geometricMean(a)
    #expect(a == aBefore)
    #expect(b == bBefore)
    a.removeAll(); b.removeAll()   // silence unused-mutation warnings
}

@Test func geometricMeanKnownValues() {
    #expect(abs(Score.geometricMean([1, 4]) - 2.0) < 1e-12)
    #expect(abs(Score.geometricMean([0.5, 2.0]) - 1.0) < 1e-12)
}

@Test func medianConfidenceIntervalIsUnboundedBelowSixObservations() {
    // At 95% the median's interval needs at least 6 per side; below that we must
    // warn rather than report an interval we cannot support.
    #expect(Score.medianConfidenceInterval([1,2,3,4,5], confidence: 0.95) == nil)
    #expect(Score.medianConfidenceInterval([1,2,3,4,5,6], confidence: 0.95) != nil)
}

@Test func nullDistributionSumsToTheTotalArrangementCount() {
    // This is the property the brief's original (wrong) implementation violated:
    // the null distribution of U must be a probability distribution over exactly
    // C(n+m, n) equally-likely arrangements, so the counts must sum to that total.
    for n in [2, 3, 4, 5] {
        let m = n
        let total = Combinatorics.binomial(n + m, n)
        let sum = MannWhitney.nullDistributionCounts(n: n, m: m).reduce(0.0) { $0 + $1.count }
        #expect(abs(sum - total) < 1e-9)
    }
}
