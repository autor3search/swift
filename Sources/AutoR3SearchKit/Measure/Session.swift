import Foundation

/// The samples collected for one benchmark across a full interleaved session.
public struct BenchmarkSamples: Sendable {
    public let benchmark: String
    public let baseline: [Double]
    public let candidate: [Double]
}

/// Runs a full baseline-vs-candidate measurement session with sides interleaved
/// round by round, so machine drift (thermal ramp, a background process
/// starting or finishing, CPU frequency scaling) lands on both sides roughly
/// equally instead of being attributed entirely to whichever side happened to
/// be measured later. See spec.md and docs/run-log.md for the measured
/// evidence that un-interleaved comparisons manufacture spurious regressions.
public enum MeasureSession {
    /// For each declared benchmark, runs `config.count` rounds. Each round
    /// samples baseline, then candidate, appending one value to each side's
    /// array; rounds repeat B, C, B, C, ... rather than running all of one
    /// side before the other, which is the entire reason this type exists.
    ///
    /// Benchmarks are measured one at a time (all of a benchmark's rounds
    /// complete before the next benchmark starts) rather than round-major
    /// across benchmarks. This keeps each benchmark's own baseline/candidate
    /// pairs maximally adjacent in time, which is the property that matters
    /// for that benchmark's own comparison; the cost is that a slow drift
    /// affecting the whole machine could differ slightly between an early
    /// benchmark and a later one in the same session, but that is drift
    /// across benchmarks, which are compared independently, not drift within
    /// a single benchmark's own baseline/candidate comparison.
    ///
    /// A throw part-way through any round (a benchmark vanished, the tool
    /// failed, a round timed out) propagates immediately rather than being
    /// swallowed. Catching it and returning what was collected so far would
    /// hand callers an incomplete, asymmetric set of samples for that
    /// benchmark — the interleaving invariant that motivated this type would
    /// already be broken for the very data being returned, and any later
    /// gate or verdict computed on it would be comparing unequal, unequally
    /// drifted sample sets while looking exactly like a normal result. There
    /// is no side-observable, self-consistent recovery inside a single
    /// benchmark's round loop, so this lets the error surface as a failed
    /// run rather than a misleadingly complete-looking one.
    public static func run(
        benchmarks: [String],
        baselineWorktree: URL,
        candidateWorktree: URL,
        source: MetricSource,
        config: Config,
        recordOrder: ((String) -> Void)? = nil
    ) throws -> [BenchmarkSamples] {
        var results: [BenchmarkSamples] = []
        results.reserveCapacity(benchmarks.count)

        for benchmark in benchmarks {
            var baseline: [Double] = []
            var candidate: [Double] = []
            baseline.reserveCapacity(config.count)
            candidate.reserveCapacity(config.count)

            for _ in 0..<config.count {
                recordOrder?("B")
                let b = try source.sample(benchmark: benchmark, in: baselineWorktree, config: config)
                baseline.append(b)

                recordOrder?("C")
                let c = try source.sample(benchmark: benchmark, in: candidateWorktree, config: config)
                candidate.append(c)
            }

            results.append(BenchmarkSamples(benchmark: benchmark, baseline: baseline, candidate: candidate))
        }

        return results
    }
}
