import Testing
import Foundation
@testable import AutoR3SearchKit

private let realOutput = """
Build complete! (4.26 secs)

Percentile\tTime (wall clock) (ns) *
0\t25500
25\t25551
50\t25583
75\t25679
100\t34833
"""

@Test func parsesP50FromThePercentileTable() throws {
    #expect(try BenchmarkToolSource.parseP50(realOutput) == 25583)
}

@Test func doesNotUseMaximumOrOtherRows() throws {
    // spec.md 2.2 finding 3: the exported `value` field sits above the 95th
    // percentile. Taking anything but row 50 would score on the noisiest sample.
    let p50 = try BenchmarkToolSource.parseP50(realOutput)
    #expect(p50 != 34833)
    #expect(p50 != 25500)
}

@Test func failsLoudlyWhenNoTableIsPresent() {
    #expect(throws: MetricError.self) {
        try BenchmarkToolSource.parseP50("Build complete!\nno table here\n")
    }
}

@Test func failsLoudlyWhenTheTableHasNoP50Row() {
    let truncated = "Percentile\tTime (wall clock) (ns) *\n0\t25500\n100\t34833"
    #expect(throws: MetricError.self) { try BenchmarkToolSource.parseP50(truncated) }
}

// MARK: - Additional coverage for the three failure modes analysed in the brief
//
// The four tests above are frozen verbatim from the brief. Everything below is
// additional coverage this task adds for the failure modes the brief asks to be
// reasoned about: a filter matching more than one benchmark, the units flag
// silently going missing, and a hung/failing `BenchmarkTool` process.

/// If `--filter` ever matched two benchmarks, the output would contain two
/// percentile tables. Taking "the first" would be an arbitrary, silently wrong
/// choice, so `parseP50` must refuse the ambiguity instead.
@Test func refusesAmbiguityWhenMoreThanOneTableIsPresent() throws {
    let twoTables = realOutput + "\n\n" + realOutput
    #expect(throws: MetricError.self) { try BenchmarkToolSource.parseP50(twoTables) }
    do {
        _ = try BenchmarkToolSource.parseP50(twoTables)
        Issue.record("expected ambiguousPercentileTable to be thrown")
    } catch let error as MetricError {
        guard case .ambiguousPercentileTable = error else {
            Issue.record("expected .ambiguousPercentileTable, got \(error)")
            return
        }
    }
}

/// If `--time-units nanoseconds` were ever dropped from the invocation, the
/// table would come back in microseconds — every number parses fine while
/// being 1000x off. The header's own unit annotation must be checked so that
/// failure is loud, not silent.
@Test func failsLoudlyWhenTheTableIsNotInNanoseconds() throws {
    let microseconds = """
    Percentile\tTime (wall clock) (us) *
    0\t25
    50\t26
    100\t34
    """
    do {
        _ = try BenchmarkToolSource.parseP50(microseconds)
        Issue.record("expected unexpectedTimeUnits to be thrown")
    } catch let error as MetricError {
        guard case .unexpectedTimeUnits = error else {
            Issue.record("expected .unexpectedTimeUnits, got \(error)")
            return
        }
    }
}

// MARK: - `sample()` against a stand-in `BenchmarkTool` executable
//
// These exercise `sample()` end to end through `Subprocess.run`, using a tiny
// shell script standing in for the real `BenchmarkTool` binary (which this
// sandbox has no compiled benchmark package to produce). They cover the
// timeout-vs-failure distinction and confirm the `--filter` value is
// anchored, both called for explicitly in the brief.

/// Removes `urls` when `body` returns OR throws, via `defer` — never a
/// trailing statement a thrown `#expect` could skip. Mirrors the helper in
/// `GitTests.swift`.
private func withTempDirectories<T>(_ urls: URL..., body: () throws -> T) rethrows -> T {
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
    return try body()
}

private func makeFakeWorktree(target: String, script: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let releaseDir = dir.appendingPathComponent(".build/release")
    try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)

    let tool = releaseDir.appendingPathComponent("BenchmarkTool")
    try script.write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

    // The benchmark executable itself is never invoked by `sample()` directly
    // (it is only passed as a path argument to BenchmarkTool), but it must
    // exist for a realistic fixture.
    let exe = releaseDir.appendingPathComponent(target)
    try "".write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

    return dir
}

private func cfg(timeoutSeconds: Int) -> Config {
    Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench", benchmarks: ["A"],
           count: 4, alpha: 0.05, minEffectPct: 1.0, maxRegressPct: 5.0,
           timeoutSeconds: timeoutSeconds)
}

@Test func sampleParsesP50FromARealProcessRun() throws {
    let script = """
    #!/bin/sh
    cat <<'BENCHEOF'
    \(realOutput)
    BENCHEOF
    """
    let worktree = try makeFakeWorktree(target: "Bench", script: script)
    try withTempDirectories(worktree) {
        let storage = worktree.appendingPathComponent("bench-storage")
        let source = BenchmarkToolSource(benchmarkTarget: "Bench", storage: storage)
        let value = try source.sample(benchmark: "A", in: worktree, config: cfg(timeoutSeconds: 30))
        #expect(value == 25583)
    }
}

/// A non-zero exit is a genuine tool failure here (unlike elsewhere in this
/// project, where a child's exit code is treated as data) — there is no
/// percentile table to score.
@Test func sampleThrowsToolFailedOnNonZeroExit() throws {
    let script = """
    #!/bin/sh
    echo "benchmark trapped" 1>&2
    exit 3
    """
    let worktree = try makeFakeWorktree(target: "Bench", script: script)
    try withTempDirectories(worktree) {
        let storage = worktree.appendingPathComponent("bench-storage")
        let source = BenchmarkToolSource(benchmarkTarget: "Bench", storage: storage)
        do {
            _ = try source.sample(benchmark: "A", in: worktree, config: cfg(timeoutSeconds: 30))
            Issue.record("expected toolFailed to be thrown")
        } catch let error as MetricError {
            guard case .toolFailed(let code, let stderr) = error else {
                Issue.record("expected .toolFailed, got \(error)")
                return
            }
            #expect(code == 3)
            #expect(stderr.contains("benchmark trapped"))
        }
    }
}

/// A hang must report distinctly from a non-zero exit: a timeout calls for a
/// different operator response (raise the timeout, or suspect a hang in the
/// benchmark) than a benchmark that ran and failed.
@Test(.timeLimit(.minutes(1)))
func sampleThrowsTimedOutRatherThanToolFailedOnAHang() throws {
    let script = """
    #!/bin/sh
    sleep 30
    """
    let worktree = try makeFakeWorktree(target: "Bench", script: script)
    try withTempDirectories(worktree) {
        let storage = worktree.appendingPathComponent("bench-storage")
        let source = BenchmarkToolSource(benchmarkTarget: "Bench", storage: storage)
        do {
            _ = try source.sample(benchmark: "A", in: worktree, config: cfg(timeoutSeconds: 1))
            Issue.record("expected timedOut to be thrown")
        } catch let error as MetricError {
            guard case .timedOut(let benchmark, _) = error else {
                Issue.record("expected .timedOut, got \(error)")
                return
            }
            #expect(benchmark == "A")
        }
    }
}

/// `--filter` is a regex matched against benchmark names. A benchmark name
/// that is a prefix of another, or contains regex metacharacters, must not
/// silently match more than intended — `sample()` anchors and escapes the
/// name it passes.
@Test func sampleAnchorsTheFilterArgument() throws {
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$(dirname "$0")/captured-args.txt"
    exit 0
    """
    let worktree = try makeFakeWorktree(target: "Bench", script: script)
    try withTempDirectories(worktree) {
        let storage = worktree.appendingPathComponent("bench-storage")
        let source = BenchmarkToolSource(benchmarkTarget: "Bench", storage: storage)
        // Exit 0 with no table still throws (noPercentileTable) — only the
        // captured argv is being checked here.
        _ = try? source.sample(benchmark: "A.B", in: worktree, config: cfg(timeoutSeconds: 30))

        let captured = try String(
            contentsOf: worktree.appendingPathComponent(".build/release/captured-args.txt"),
            encoding: .utf8)
        #expect(captured.contains("^A\\.B$"),
                "filter must be anchored and regex-escaped, got: \(captured)")
    }
}

/// `BenchmarkTool` REQUIRES `--grouping <grouping>`; omitting it fails before
/// any benchmark runs at all (verified against `ordo-one/benchmark` 1.36.2:
/// the exact argument list below it, minus this flag, exits 64 with
/// "Missing expected argument '--grouping <grouping>'"). `benchmark` is the
/// correct value here, not `metric`: each invocation is already filtered to
/// one benchmark name and one metric (`wallClock`), and `benchmark` grouping
/// is what produces the flat per-benchmark percentile table `parseP50`
/// expects. This binds the literal argument vector — the only thing that
/// would have caught this flag being dropped — so a future edit that removes
/// or reorders it fails here instead of surfacing as an exit-64 the first
/// time the real tool is invoked.
@Test func sampleIncludesTheRequiredGroupingArgument() throws {
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$(dirname "$0")/captured-args.txt"
    exit 0
    """
    let worktree = try makeFakeWorktree(target: "Bench", script: script)
    try withTempDirectories(worktree) {
        let storage = worktree.appendingPathComponent("bench-storage")
        let source = BenchmarkToolSource(benchmarkTarget: "Bench", storage: storage)
        // Exit 0 with no table still throws (noPercentileTable) — only the
        // captured argv is being checked here.
        _ = try? source.sample(benchmark: "A", in: worktree, config: cfg(timeoutSeconds: 30))

        let captured = try String(
            contentsOf: worktree.appendingPathComponent(".build/release/captured-args.txt"),
            encoding: .utf8)
        let argv = captured.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        guard let groupingIndex = argv.firstIndex(of: "--grouping") else {
            Issue.record("argv does not contain --grouping at all: \(argv)")
            return
        }
        #expect(groupingIndex + 1 < argv.count && argv[groupingIndex + 1] == "benchmark",
                "expected --grouping to be immediately followed by \"benchmark\", got: \(argv)")
    }
}
