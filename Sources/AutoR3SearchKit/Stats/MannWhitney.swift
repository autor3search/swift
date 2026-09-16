import Foundation

public enum MannWhitney {
    /// Exact two-sided Mann-Whitney U. Rank-based, so a single wild outlier
    /// contributes only its rank - which is why it is the right test for Swift
    /// benchmark noise (see spec.md 2.3).
    public static func twoSidedP(_ a: [Double], _ b: [Double]) -> Double {
        let x = a, y = b                       // defensive copies; never sort the caller's arrays
        let n = x.count, m = y.count
        guard n > 0, m > 0 else { return 1.0 }

        var u = 0.0
        for xi in x {
            for yj in y {
                if xi > yj { u += 1 } else if xi == yj { u += 0.5 }
            }
        }
        let uMin = min(u, Double(n * m) - u)
        let counts = nullDistributionCounts(n: n, m: m)
        let total = Combinatorics.binomial(n + m, n)
        var tail = 0.0
        for entry in counts where entry.u <= uMin + 1e-9 { tail += entry.count }
        return min(1.0, 2.0 * tail / total)
    }

    /// Exact null distribution of the Mann-Whitney U statistic for samples of
    /// size `n` and `m`, indexed by integer `u` from 0 to n*m.
    ///
    /// f(n, m, u) is the number of ways to interleave n "low" tokens and m
    /// "high" tokens (i.e. arrangements of the pooled ranks into a group of n
    /// and a group of m) such that the resulting U statistic equals u. This is
    /// exactly the number of partitions of u that fit in an n x m box, given by
    /// the recurrence:
    ///
    ///     f(n, m, u) = f(n-1, m, u-m) + f(n, m-1, u)
    ///     f(0, m, u) = f(n, 0, u) = 1 if u == 0 else 0
    ///     f(n, m, u) = 0 for u < 0
    ///
    /// Summed over all u this totals C(n+m, n): the null distribution is
    /// uniform over the C(n+m, n) equally-likely arrangements of the pooled
    /// sample, which is the property the two-sided p-value depends on.
    ///
    /// (An earlier draft of this function counted ordered compositions
    /// instead of partitions-in-a-box, which overcounts: for n=m=3 it summed
    /// to 64 instead of the required C(6,3) = 20. This implementation is
    /// verified against `nullDistributionSumsToTheTotalArrangementCount`.)
    ///
    /// Internal (not `private`) so tests can assert the sum-to-C(n+m,n)
    /// property directly via `@testable import`.
    internal static func nullDistributionCounts(n: Int, m: Int) -> [(u: Double, count: Double)] {
        let maxU = n * m
        let width = maxU + 1
        // Flat (m+1) x width grids, row-major: index = col*width + u.
        // prev holds f(i-1, col, u); curr holds f(i, col, u). Both buffers are
        // allocated once and reused across iterations (no per-column/per-row
        // allocation) - this is what keeps the DP fast at n, m up to ~100.
        var prev = [Double](repeating: 0, count: (m + 1) * width)
        for col in 0...m { prev[col * width] = 1 }   // f(0, col, u) = 1 if u == 0 else 0

        if n > 0 {
            var curr = [Double](repeating: 0, count: (m + 1) * width)
            for _ in 1...n {
                // f(i, 0, u) = 1 if u == 0 else 0 - reset column 0 in place.
                for u in 1..<width { curr[u] = 0 }
                curr[0] = 1
                if m > 0 {
                    for col in 1...m {
                        let base = col * width
                        let prevColBase = col * width
                        let currPrevColBase = (col - 1) * width
                        for u in 0..<width {
                            let fromPrevN = u >= col ? prev[prevColBase + u - col] : 0
                            let fromPrevM = curr[currPrevColBase + u]
                            curr[base + u] = fromPrevN + fromPrevM
                        }
                    }
                }
                swap(&prev, &curr)
            }
        }
        let base = m * width
        return (0..<width).map { (Double($0), prev[base + $0]) }
    }

    /// The smallest two-sided p attainable with `n` rounds per side.
    public static func pValueFloor(roundsPerSide n: Int) -> Double {
        2.0 / Combinatorics.binomial(2 * n, n)
    }

    /// Largest k for which the Bonferroni-corrected alpha/k still sits at or above
    /// the floor. Beyond this, every experiment discards no matter how good it is.
    public static func maxBenchmarksWithReachableKeep(roundsPerSide n: Int, alpha: Double) -> Int {
        let floor = pValueFloor(roundsPerSide: n)
        guard floor > 0 else { return Int.max }
        return Int((alpha / floor).rounded(.down))
    }
}
