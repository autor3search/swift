import Foundation

/// Measures one benchmark by invoking the already-built `BenchmarkTool`
/// executable directly.
///
/// Never drives `swift package benchmark run`: that plugin path costs ~15s per
/// invocation AND contaminates the measurement, because SwiftPM performs
/// build-graph work concurrently with the benchmark (spec.md 2.2). Eight
/// plugin-driven runs of an identical benchmark produced p50 values spread
/// across a 77% range on code that did not change; the same benchmark,
/// measured by invoking `BenchmarkTool` directly against an already-built
/// binary, took 0.05s. So: build with `swift build` (elsewhere in the
/// pipeline), measure here by shelling out to `BenchmarkTool` only.
public struct BenchmarkToolSource: MetricSource {
    public let benchmarkTarget: String
    public let storage: URL

    public init(benchmarkTarget: String, storage: URL) {
        self.benchmarkTarget = benchmarkTarget
        self.storage = storage
    }

    /// Row 50 of the `--format histogramPercentiles` table. The exported
    /// `value` field (from `jsonSmallerIsBetter` et al.) sits at or near the
    /// MAXIMUM of the run — the noisiest observation — and must never be used
    /// as the sample; this parses the explicit percentile table instead and
    /// reads row 50 by name.
    ///
    /// Refuses rather than guesses in three cases: no table at all (a
    /// `--filter` that matched no benchmark, e.g. a typo in
    /// `config.benchmarks`, must not silently produce zero samples), more
    /// than one table (an unintentionally broad `--filter` regex matching
    /// multiple benchmarks — taking "the first" would be an arbitrary,
    /// wrong-by-construction choice), and a table not reported in
    /// nanoseconds (catches `--time-units nanoseconds` silently going
    /// missing, which would otherwise parse fine while being 1000x off).
    public static func parseP50(_ stdout: String) throws -> Double {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)

        let headerIndices = lines.indices.filter { lines[$0].hasPrefix("Percentile") }
        guard !headerIndices.isEmpty else {
            throw MetricError.noPercentileTable(stdout)
        }
        guard headerIndices.count == 1 else {
            throw MetricError.ambiguousPercentileTable(stdout)
        }
        let header = lines[headerIndices[0]]
        guard header.contains("(ns)") else {
            throw MetricError.unexpectedTimeUnits(String(header))
        }

        for line in lines[(headerIndices[0] + 1)...] {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard cols.count >= 2,
                  cols[0].trimmingCharacters(in: .whitespaces) == "50"
            else { continue }
            guard let value = Double(cols[1].trimmingCharacters(in: .whitespaces)) else { continue }
            return value
        }
        throw MetricError.missingP50(stdout)
    }

    /// One process run, one number: `BenchmarkTool`'s own `histogramSamples`
    /// format would hand back thousands of per-iteration observations, but
    /// those are correlated within a single process and would manufacture
    /// significance if fed to a rank test (spec.md 6). The sample for a round
    /// is the p50 of exactly one process invocation.
    public func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        let tool = worktree.appendingPathComponent(".build/release/BenchmarkTool")
        let exe = worktree.appendingPathComponent(".build/release/\(benchmarkTarget)")

        // `--filter` is a regex matched against benchmark names. Anchoring an
        // escaped copy of the exact name keeps a benchmark name that happens to
        // contain regex metacharacters, or that is a prefix of another
        // benchmark's name, from matching more than the one benchmark intended.
        let escaped = NSRegularExpression.escapedPattern(for: benchmark)
        let anchoredFilter = "^\(escaped)$"

        let r = try Subprocess.run(tool, [
            "--command", "run",
            "--format", "histogramPercentiles",
            "--time-units", "nanoseconds",
            "--path", "stdout",
            "--no-progress",
            "--metrics", "wallClock",
            "--filter", anchoredFilter,
            "--benchmark-executable-paths", exe.path,
            "--baseline-storage-path", storage.path,
            "--target-name", benchmarkTarget,
            "--targets", benchmarkTarget,
        ], cwd: worktree, env: nil, timeout: TimeInterval(config.timeoutSeconds))

        // Distinguished from a non-zero exit: a hang calls for a different
        // operator response (raise the timeout, or suspect the benchmark
        // itself) than a benchmark that ran and failed.
        guard !r.timedOut else {
            throw MetricError.timedOut(benchmark, TimeInterval(config.timeoutSeconds))
        }
        guard r.exitCode == 0 else {
            throw MetricError.toolFailed(r.exitCode, r.stderr)
        }
        return try BenchmarkToolSource.parseP50(r.stdout)
    }
}
