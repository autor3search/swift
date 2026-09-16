import Foundation

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case badVersion(Int)
    case emptyScope
    case emptyBenchmarks
    case countTooSmall(Int)
    case badAlpha(Double)

    public var description: String {
        switch self {
        case .badVersion(let v):
            return "unsupported config version \(v); this tool understands version 1"
        case .emptyScope:
            return "scope is empty: the agent would be allowed to edit nothing"
        case .emptyBenchmarks:
            return """
            benchmarks is empty. This tool has no other notion of "faster": the verdict is \
            entirely a function of the declared benchmarks' timings. With none declared, every \
            candidate would be accepted for no reason or rejected for no reason. Declare at \
            least one benchmark and re-run init.
            """
        case .countTooSmall(let n):
            return """
            count is \(n), which can never reach significance. Mann-Whitney is a rank test: \
            the smallest two-sided p attainable is 2/C(2n,n) - 0.33 at count 2, 0.10 at count 3 \
            - both above any sensible alpha. Every experiment would DISCARD on a technicality \
            rather than on its merits. Use count >= 4.
            """
        case .badAlpha(let a):
            return "alpha must be between 0 and 1, got \(a)"
        }
    }
}

extension Config {
    /// Structural and statistical sanity checks that don't depend on how
    /// many benchmarks a given run compares. See `keepReachabilityWarning()`
    /// for the check that does.
    public func validate() throws {
        guard version == 1 else { throw ConfigError.badVersion(version) }
        guard !scope.isEmpty else { throw ConfigError.emptyScope }
        guard !benchmarks.isEmpty else { throw ConfigError.emptyBenchmarks }
        guard count >= 4 else { throw ConfigError.countTooSmall(count) }
        guard alpha > 0, alpha < 1 else { throw ConfigError.badAlpha(alpha) }
    }

    /// `validate()` cannot catch this: it does not know how many benchmarks a run
    /// will compare. When the Bonferroni-corrected alpha/k falls below the
    /// p-value floor for this count, no KEEP is reachable however good the
    /// change is. Checked again at eval time, when k is known for real.
    public func keepReachabilityWarning() -> String? {
        let k = benchmarks.count
        guard k > 0 else { return nil }
        let corrected = alpha / Double(k)
        let floor = MannWhitney.pValueFloor(roundsPerSide: count)
        guard corrected < floor else { return nil }
        var needed = count
        while needed < 100, corrected < MannWhitney.pValueFloor(roundsPerSide: needed) {
            needed += 1
        }
        return """
        no KEEP is reachable with count \(count) and \(k) benchmarks: the Bonferroni-corrected \
        threshold alpha/k = \(String(format: "%.5f", corrected)) is below the smallest p this \
        test can produce, \(String(format: "%.5f", floor)). Every experiment will DISCARD \
        however good the change is. Raise count to \(needed).
        """
    }
}
