import Foundation

/// The four terminal states of a run, and the exit code each maps to. This is
/// the contract the executable's `main` translates directly into `exit()`.
public enum VerdictKind: String, Codable, Sendable {
    case keep, discard, fail, crash
    public var exitCode: Int32 {
        switch self {
        case .keep: 0
        case .discard: 1
        case .fail: 2
        case .crash: 3
        }
    }
}

/// One benchmark's measured comparison. `significantAtAlpha` is the raw,
/// honest statistic - always uncorrected, so a human reading a report sees
/// the number a textbook would compute. `significantAtCorrected` is the
/// KEEP-decision threshold layered on top for rule 2; it is not a
/// redefinition of "significant" and must not replace the uncorrected field
/// anywhere it is reported.
public struct BenchmarkDelta: Codable, Sendable {
    public let benchmark: String
    public let baselineMedian: Double
    public let candidateMedian: Double
    public let ratio: Double
    public let pValue: Double
    public let significantAtAlpha: Bool
    public let significantAtCorrected: Bool

    // Explicit public init: the synthesised memberwise initialiser on a
    // public struct is only internal, so the executable target (which
    // constructs Verdict/BenchmarkDelta values directly for .fail/.crash
    // cases - see Task 17) could not otherwise build one.
    public init(
        benchmark: String,
        baselineMedian: Double,
        candidateMedian: Double,
        ratio: Double,
        pValue: Double,
        significantAtAlpha: Bool,
        significantAtCorrected: Bool
    ) {
        self.benchmark = benchmark
        self.baselineMedian = baselineMedian
        self.candidateMedian = candidateMedian
        self.ratio = ratio
        self.pValue = pValue
        self.significantAtAlpha = significantAtAlpha
        self.significantAtCorrected = significantAtCorrected
    }
}

public struct Verdict: Sendable {
    public let kind: VerdictKind
    public let score: Double
    public let deltas: [BenchmarkDelta]
    public let reason: String?
    public let warnings: [String]
    public let unsafeHits: [UnsafeHit]
    public let buildConfiguration: String
    public let stopRequested: Bool

    // Explicit public init, for the same reason as BenchmarkDelta's above:
    // Task 17's CLI must be able to construct .fail and .crash verdicts
    // itself when a gate rejects or the harness throws, outside of
    // Scoring.decide.
    public init(
        kind: VerdictKind,
        score: Double,
        deltas: [BenchmarkDelta],
        reason: String?,
        warnings: [String],
        unsafeHits: [UnsafeHit],
        buildConfiguration: String,
        stopRequested: Bool
    ) {
        self.kind = kind
        self.score = score
        self.deltas = deltas
        self.reason = reason
        self.warnings = warnings
        self.unsafeHits = unsafeHits
        self.buildConfiguration = buildConfiguration
        self.stopRequested = stopRequested
    }
}

/// THE VERDICT. KEEP requires all three of:
///
///   1. `score < 1 - minEffectPct/100` - statistically significant is not
///      enough; the win has to be big enough to be worth an unattended
///      commit.
///   2. At least one benchmark significant at the Bonferroni-corrected
///      `alpha / k` - conservative about accepting a win, because testing k
///      benchmarks against the same uncorrected alpha inflates the chance
///      that one shows a spurious "significant" result by luck.
///   3. No significant regression beyond `maxRegressPct`, evaluated at the
///      UNCORRECTED alpha - liberal about catching harm. Applying the
///      Bonferroni correction here (i.e. requiring alpha/k to flag a
///      regression) would only make real regressions *harder* to detect,
///      which is backwards for a harm guard: see `regressionAlpha` and
///      docs/run-log.md's Task 13 mutation evidence for the measured case
///      this asymmetry catches and a "consistent" alpha/k regression guard
///      misses.
///
/// See spec.md 7.
public enum Scoring {
    /// The corrected alpha used for rule 2 (accepting a win). Always divides
    /// by the number of benchmarks *declared* in config, not the number
    /// actually measured in a given call to `decide` - this is a
    /// general-purpose, samples-independent figure (e.g. for pre-flight
    /// "is a KEEP even reachable at this count" checks against the full
    /// declared benchmark set), which is exactly why the fixed interface
    /// gives it only `config` and no `samples` parameter. `decide` itself
    /// corrects against the benchmarks actually compared in that call (see
    /// the `k` local there) - that is the family of hypothesis tests this
    /// specific decision is actually making, which is what a multiple-
    /// comparisons correction must be sized to; declared-but-unmeasured
    /// benchmarks contribute no test and are not part of that family.
    public static func keepAlpha(config: Config) -> Double {
        config.alpha / Double(max(config.benchmarks.count, 1))
    }

    /// Deliberately uncorrected: the harm guard (rule 3) trades the other
    /// way from rule 2. Bonferroni only ever makes significance HARDER to
    /// declare; applying it here would make real regressions easier to
    /// miss, which is the opposite of what a guard against overnight, agent-
    /// driven regressions should do. Do not "fix" this to match
    /// `keepAlpha` - see the type-level doc comment above.
    public static func regressionAlpha(config: Config) -> Double {
        config.alpha
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func decide(
        samples: [BenchmarkSamples],
        config: Config,
        unsafeHits: [UnsafeHit],
        stopRequested: Bool
    ) -> Verdict {
        var warnings: [String] = []

        // k is the number of benchmarks actually being compared in *this*
        // decision - the real family of hypothesis tests - not the size of
        // the declared config.benchmarks list, which can be larger (or, in
        // principle, smaller) than what was actually measured this run.
        let k = max(samples.count, 1)
        let corrected = config.alpha / Double(k)

        let floor = MannWhitney.pValueFloor(roundsPerSide: config.count)
        if corrected < floor {
            var needed = config.count
            while needed < 100, config.alpha / Double(k) < MannWhitney.pValueFloor(roundsPerSide: needed) {
                needed += 1
            }
            warnings.append("""
            no KEEP is reachable: alpha/k = \(String(format: "%.5f", corrected)) is below the \
            smallest p this test can produce at count \(config.count) \
            (\(String(format: "%.5f", floor))). Raise count to \(needed).
            """)
        }
        if config.count < 6 {
            warnings.append("count \(config.count) is below 6, so the median's 95% confidence interval is unbounded")
        }

        // Empty samples: never KEEP, never let NaN sneak through a
        // comparison. score is reported as .nan (there is nothing to score)
        // rather than silently defaulting to some finite number that would
        // look like a real measurement. Every comparison further down this
        // function (`score < effectThreshold`, for instance) is `false` for
        // NaN in Swift, which fails closed on its own (never KEEP) - but we
        // do not rely on that here; we return early and explicitly instead.
        guard !samples.isEmpty else {
            return Verdict(
                kind: .discard, score: .nan, deltas: [], reason: "no_measurements",
                warnings: warnings, unsafeHits: unsafeHits,
                buildConfiguration: "release", stopRequested: stopRequested
            )
        }

        var deltas: [BenchmarkDelta] = []
        for s in samples {
            let bm = median(s.baseline)
            let cm = median(s.candidate)
            let p = MannWhitney.twoSidedP(s.baseline, s.candidate)
            deltas.append(BenchmarkDelta(
                benchmark: s.benchmark, baselineMedian: bm, candidateMedian: cm,
                ratio: cm / bm, pValue: p,
                significantAtAlpha: p < config.alpha,
                significantAtCorrected: p < corrected
            ))
        }

        // score: geometric mean of per-benchmark ratios. geometricMean
        // returns NaN if any ratio is <= 0, which cannot happen here from
        // real timings (a median of positive samples is positive, so
        // ratio = candidateMedian / baselineMedian > 0) but is handled
        // safely regardless: every `score < threshold` comparison below is
        // false for NaN, so a NaN score can never satisfy rule 1 and can
        // never produce a KEEP.
        let score = Score.geometricMean(deltas.map(\.ratio))

        // Rule 3 FIRST, ahead of the improvement rules, and evaluated at the
        // uncorrected alpha. A change that both improves overall and
        // significantly regresses one benchmark must be rejected outright -
        // speeding up A by wrecking B is not a win, no matter how good the
        // aggregate score looks - and the reported reason must say
        // "significant_regression", not one of the improvement reasons,
        // so the agent's next move is "fix the regression", not "try a
        // different idea" or "go bigger on the same idea".
        let regressionLimit = 1.0 + config.maxRegressPct / 100.0
        let regressionAlphaValue = regressionAlpha(config: config)
        if deltas.contains(where: { $0.ratio > regressionLimit && $0.pValue < regressionAlphaValue }) {
            return Verdict(
                kind: .discard, score: score, deltas: deltas,
                reason: "significant_regression", warnings: warnings,
                unsafeHits: unsafeHits, buildConfiguration: "release",
                stopRequested: stopRequested
            )
        }

        // Rule 2: at least one benchmark must be a significant win at the
        // Bonferroni-corrected alpha. If none is, nothing measurably moved -
        // "no_significant_improvement" - and the agent's next move is to
        // try a different idea.
        let anySignificantWin = deltas.contains { $0.significantAtCorrected && $0.ratio < 1.0 }
        if !anySignificantWin {
            return Verdict(
                kind: .discard, score: score, deltas: deltas,
                reason: "no_significant_improvement", warnings: warnings,
                unsafeHits: unsafeHits, buildConfiguration: "release",
                stopRequested: stopRequested
            )
        }

        // Rule 1: the win has to clear the minimum-effect floor. This is
        // distinct from "no significant improvement" - the direction was
        // right, it just wasn't big enough - so the agent's next move is to
        // go bigger on the same idea, not abandon it.
        let effectThreshold = 1.0 - config.minEffectPct / 100.0
        guard score < effectThreshold else {
            return Verdict(
                kind: .discard, score: score, deltas: deltas,
                reason: "improvement_below_min_effect", warnings: warnings,
                unsafeHits: unsafeHits, buildConfiguration: "release",
                stopRequested: stopRequested
            )
        }

        return Verdict(
            kind: .keep, score: score, deltas: deltas, reason: nil,
            warnings: warnings, unsafeHits: unsafeHits,
            buildConfiguration: "release", stopRequested: stopRequested
        )
    }
}
