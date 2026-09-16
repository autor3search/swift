import Foundation

/// One number per process run. Never per-iteration samples: those are correlated
/// within a process and would manufacture significance (spec.md 6).
public protocol MetricSource: Sendable {
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double
}

public enum MetricError: Error, CustomStringConvertible {
    /// The tool's stdout contains no `Percentile` header row at all. Covers both
    /// a benchmark name that matched nothing (a typo in `config.benchmarks`) and
    /// any other case where the expected table simply never showed up. Either
    /// way this must fail loudly rather than let a caller fall through to a
    /// garbage number.
    case noPercentileTable(String)

    /// A percentile table was found but has no `50` row (e.g. truncated output).
    case missingP50(String)

    /// More than one `Percentile` header appeared in one run's stdout. `--filter`
    /// is a regex matched against benchmark names; a name containing regex
    /// metacharacters, or one name being a prefix of another, could make it
    /// match more than the single intended benchmark. Rather than silently
    /// taking the first table found (an arbitrary, wrong-by-construction
    /// choice), this refuses the ambiguity outright.
    case ambiguousPercentileTable(String)

    /// The percentile table's header does not report nanoseconds. `sample`
    /// always passes `--time-units nanoseconds`; if that flag were ever
    /// dropped, the table would be reported in microseconds and every number
    /// would parse fine while being 1000x off. Checking the header's unit
    /// annotation turns that into a loud failure instead of a silent one.
    case unexpectedTimeUnits(String)

    /// `BenchmarkTool` exited non-zero. A benchmark that itself fails (traps,
    /// throws, etc.) is a genuine tool failure here, not "data" the way a
    /// non-zero exit is elsewhere in this project — there is no percentile
    /// table to score in that case.
    case toolFailed(Int32, String)

    /// `BenchmarkTool` did not finish within `config.timeoutSeconds` and its
    /// process tree was killed. Kept distinct from `toolFailed`: a timeout
    /// calls for a different operator response (raise the timeout, or suspect
    /// a hang in the benchmark itself) than a benchmark that ran and failed.
    case timedOut(String, TimeInterval)

    public var description: String {
        switch self {
        case .noPercentileTable:
            return "BenchmarkTool produced no percentile table"
        case .missingP50:
            return "BenchmarkTool's percentile table has no row 50"
        case .ambiguousPercentileTable:
            return "BenchmarkTool's output contains more than one percentile table; " +
                "refusing to guess which one the requested benchmark corresponds to"
        case .unexpectedTimeUnits:
            return "BenchmarkTool's percentile table is not reported in nanoseconds " +
                "(the \"(ns)\" unit marker is missing from its header) — check that " +
                "--time-units nanoseconds is still being passed"
        case .toolFailed(let rc, let err):
            return "BenchmarkTool exited \(rc): \(err)"
        case .timedOut(let benchmark, let timeout):
            return "BenchmarkTool timed out after \(timeout)s running \"\(benchmark)\""
        }
    }
}
