import Testing
import Foundation
@testable import AutoR3SearchKit

/// Records the order in which sides were sampled, and returns scripted values.
private final class SpySource: MetricSource, @unchecked Sendable {
    var order: [String] = []
    let baselineURL: URL
    init(baselineURL: URL) { self.baselineURL = baselineURL }
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        let side = worktree == baselineURL ? "B" : "C"
        order.append(side)
        return side == "B" ? 100 : 80
    }
}

private func cfg(count: Int) -> Config {
    Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench", benchmarks: ["A"],
           count: count, alpha: 0.05, minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
}

@Test func alternatesSidesWithinOneSession() throws {
    let b = URL(fileURLWithPath: "/tmp/base"), c = URL(fileURLWithPath: "/tmp/cand")
    let spy = SpySource(baselineURL: b)
    _ = try MeasureSession.run(benchmarks: ["A"], baselineWorktree: b, candidateWorktree: c,
                               source: spy, config: cfg(count: 4), recordOrder: nil)
    #expect(spy.order == ["B", "C", "B", "C", "B", "C", "B", "C"],
            "sides must interleave so thermal drift cancels rather than being attributed to the change")
}

@Test func collectsCountSamplesPerSide() throws {
    let b = URL(fileURLWithPath: "/tmp/base"), c = URL(fileURLWithPath: "/tmp/cand")
    let spy = SpySource(baselineURL: b)
    let out = try MeasureSession.run(benchmarks: ["A"], baselineWorktree: b, candidateWorktree: c,
                                     source: spy, config: cfg(count: 6), recordOrder: nil)
    #expect(out.count == 1)
    #expect(out[0].baseline.count == 6)
    #expect(out[0].candidate.count == 6)
    #expect(out[0].baseline.allSatisfy { $0 == 100 })
    #expect(out[0].candidate.allSatisfy { $0 == 80 })
}

@Test func measuresEveryDeclaredBenchmark() throws {
    let b = URL(fileURLWithPath: "/tmp/base"), c = URL(fileURLWithPath: "/tmp/cand")
    let spy = SpySource(baselineURL: b)
    let out = try MeasureSession.run(benchmarks: ["A", "B"], baselineWorktree: b, candidateWorktree: c,
                                     source: spy, config: cfg(count: 4), recordOrder: nil)
    #expect(out.map(\.benchmark) == ["A", "B"])
}

/// Collects everything a `recordOrder` callback emits, in call order.
///
/// None of the three tests above ever pass a non-nil `recordOrder`, so nothing
/// checks that the callback itself reports the side actually being sampled —
/// `alternatesSidesWithinOneSession` verifies ordering entirely through
/// `SpySource.order`, which is populated inside `sample(benchmark:in:config:)`
/// by comparing the worktree argument, never by consulting `recordOrder`. A
/// `recordOrder` that reported the wrong side, fired once instead of twice per
/// round, or fired out of position would pass all three frozen tests
/// unnoticed. This closes that gap without touching any of them.
private final class OrderRecorder: @unchecked Sendable {
    var recorded: [String] = []
}

@Test func recordOrderCallbackAgreesWithActualSamplingOrder() throws {
    let b = URL(fileURLWithPath: "/tmp/base"), c = URL(fileURLWithPath: "/tmp/cand")
    let spy = SpySource(baselineURL: b)
    let recorder = OrderRecorder()
    _ = try MeasureSession.run(benchmarks: ["A"], baselineWorktree: b, candidateWorktree: c,
                               source: spy, config: cfg(count: 4),
                               recordOrder: { recorder.recorded.append($0) })

    // The callback alone must alternate for all 2*count entries...
    #expect(recorder.recorded == ["B", "C", "B", "C", "B", "C", "B", "C"],
            "recordOrder must itself alternate B, C, ... across the session")

    // ...and, decisively, it must agree with the side `SpySource` independently
    // observed being sampled (derived from the worktree argument, not from
    // recordOrder). Checking only the callback's own shape would let a
    // recordOrder that alternates but reports the wrong side, or a call site
    // that invokes it without actually sampling that side, pass unnoticed;
    // cross-checking against an independent witness rules both out.
    #expect(recorder.recorded == spy.order,
            "recordOrder must report exactly the side actually sampled, in the order it was actually sampled")
}
