import Foundation

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case badVersion(Int)
    case emptyScope
    case emptyBenchmarks
    case countTooSmall(Int)
    case badAlpha(Double)

    /// `benchmark_package_path` names a location this tool will not address.
    /// The `why` is `BenchmarkPackage.Invalid`'s own description, which names
    /// the specific rule that was broken rather than restating a generic one.
    case badBenchmarkPackagePath(String, String)

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
            rather than on its merits. Use count >= 4. Note that 4 is the ALPHA-INDEPENDENT \
            floor, not advice: whether YOUR count reaches significance depends on your alpha \
            and your benchmark count, and at the shipped default alpha of 0.005 the smallest \
            workable count is 6 even with a single benchmark (the floor is 0.0079 at count 5 \
            and 0.0022 at count 6). `keepReachabilityWarning()` checks that against your \
            actual numbers; this check cannot, because it does not know them.
            """
        case .badAlpha(let a):
            return "alpha must be between 0 and 1, got \(a)"
        case .badBenchmarkPackagePath(_, let why):
            return why
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
        // Structural only -- `validate()` is called from places with no
        // repository URL to hand. The "and it really contains a Package.swift"
        // half is `validateBenchmarkPackage(in:)` below, called by every
        // command that has one.
        if let path = benchmarkPackagePath {
            do { try BenchmarkPackage.validateShape(path) }
            catch { throw ConfigError.badBenchmarkPackagePath(path, "\(error)") }
        }
    }

    /// The disk half of `benchmark_package_path`'s validation: the configured
    /// directory must exist inside `repo` and hold a `Package.swift`.
    ///
    /// SEPARATE FROM `validate()` ON PURPOSE. `validate()` is a pure function
    /// over the config's own values and is called on fabricated configs in
    /// tests and on a config `init` has only just built in memory; folding a
    /// filesystem probe into it would make those callers depend on a
    /// repository they do not have. This is called by `eval` (as part of gate
    /// 2's config handling), by `baseline`, and by `doctor`, each of which is
    /// looking at a real repository.
    ///
    /// A no-op when the key is absent, which is what keeps the root-package
    /// layout byte-for-byte unaffected.
    public func validateBenchmarkPackage(in repo: URL) throws {
        guard let path = benchmarkPackagePath else { return }
        do { try BenchmarkPackage.validate(path, in: repo) }
        catch { throw ConfigError.badBenchmarkPackagePath(path, "\(error)") }
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
        // `%.3g`, not `%.5f`: at the shipped default alpha of 0.005 the
        // interesting quantities are routinely smaller than 1e-5 (the p-value
        // floor at count 10 is 1.08e-5), and `%.5f` renders every one of them
        // as the string "0.00000" -- a diagnostic that prints two equal-looking
        // zeroes and asks the reader to believe one is below the other.
        return """
        no KEEP is reachable with count \(count) and \(k) benchmarks: the Bonferroni-corrected \
        threshold alpha/k = \(String(format: "%.3g", corrected)) is below the smallest p this \
        test can produce, \(String(format: "%.3g", floor)). Every experiment will DISCARD \
        however good the change is. Raise count to \(needed).
        """
    }
}
