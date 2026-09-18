import Foundation

public enum Score {
    public static func geometricMean(_ ratios: [Double]) -> Double {
        let xs = ratios                        // defensive copy
        guard !xs.isEmpty, xs.allSatisfy({ $0 > 0 }) else { return .nan }
        let logSum = xs.reduce(0.0) { $0 + Foundation.log($1) }
        return Foundation.exp(logSum / Double(xs.count))
    }

    /// Distribution-free interval from the binomial order statistics. Returns nil
    /// when n is too small for the requested confidence, so callers warn instead
    /// of reporting an interval the data cannot support.
    ///
    /// Uses the standard order-statistic construction (Conover, *Practical
    /// Nonparametric Statistics*): the number of observations below the true
    /// median is Binomial(n, 0.5), so `(X_(k), X_(n+1-k))` (1-indexed) covers
    /// the median with probability `1 - 2*P(Bin(n,0.5) <= k-1)`. `k` is chosen
    /// via the normal approximation to the binomial with a continuity
    /// correction, then floored so the achieved coverage is never below the
    /// requested confidence.
    public static func medianConfidenceInterval(_ xs: [Double], confidence: Double) -> (low: Double, high: Double)? {
        guard confidence > 0, confidence < 1 else { return nil }
        let s = xs.sorted()                    // sorted() returns a new array; never mutates xs
        let n = s.count
        guard n > 0 else { return nil }

        let z = inverseNormalCDF(0.5 + confidence / 2.0)
        let k = Int((Double(n) / 2.0 + 0.5 - z * Foundation.sqrt(Double(n)) / 2.0).rounded(.down))
        let lowIdx = k - 1                     // 0-indexed
        let highIdx = n - k                    // 0-indexed
        guard k >= 1, lowIdx >= 0, highIdx < n, lowIdx <= highIdx else { return nil }
        return (s[lowIdx], s[highIdx])
    }

    /// Inverse standard normal CDF (probit function), via Acklam's rational
    /// approximation (accurate to about 1.15e-9). Used to turn a requested
    /// confidence level into a z-score for `medianConfidenceInterval`.
    private static func inverseNormalCDF(_ p: Double) -> Double {
        precondition(p > 0 && p < 1)
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                  1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                  6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let pLow = 0.02425
        let pHigh = 1 - pLow

        if p < pLow {
            let q = Foundation.sqrt(-2 * Foundation.log(p))
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                   ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= pHigh {
            let q = p - 0.5
            let r = q * q
            return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                   (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = Foundation.sqrt(-2 * Foundation.log(1 - p))
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                    ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
    }
}
