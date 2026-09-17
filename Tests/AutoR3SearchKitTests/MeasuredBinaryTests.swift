import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/MeasuredBinaryTests.swift
//
// THE ELEVENTH VECTOR, AND A THIRD FAMILY. The first family asked "does the
// COMPILER read it?"; the second asked "does the HARNESS RUN it?" -- git hooks,
// filter drivers, the environment handed to helper subprocesses. This one is
// what neither covers: the harness EXECUTES THE AGENT'S OWN BENCHMARK, and that
// process runs as the same user, on the same filesystem, with the pinned
// baseline worktree at a path it can compute.
//
// Measured against the real binary before this guard existed, from a commit
// whose entire diff is one in-scope source file holding the ORIGINAL quadratic
// algorithm plus a lazily-initialised global:
//
//   attacked: rc 0  keep  ratio 0.04973  baseline 73.30 ms  candidate 3.65 ms  warnings []
//   next, FULLY HONEST eval: rc 0 keep ratio 0.05069 against a 71.34 ms baseline
//
// The global rewrote the pinned worktree's benchmark to 35000 repeats and
// rebuilt it; on KEEP the SOURCE was git-restored, erasing the trace, while the
// inflated BINARY survived into the next experiment. That is the stale-baseline
// coasting bug this project exists to prevent, reached through a door no gate
// was watching.

private struct NeverSampled: MetricSource {
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        Issue.record("the guard should have refused before delegating")
        return 0
    }
}

/// Samples normally, but runs `sabotage` after the Nth delegated sample -- the
/// benchmark process doing something to the filesystem while it is measured.
private final class SabotagingSource: MetricSource, @unchecked Sendable {
    let after: Int
    let sabotage: () -> Void
    var delegated = 0
    init(after: Int, sabotage: @escaping () -> Void) {
        self.after = after
        self.sabotage = sabotage
    }
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        delegated += 1
        if delegated == after { sabotage() }
        return 100.0
    }
}

private func fakeBinaries(_ root: URL, target: String, bytes: String) throws -> [URL] {
    var made: [URL] = []
    for name in [target, "BenchmarkTool"] {
        let url = root.appendingPathComponent(".build/release/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, atomically: true, encoding: .utf8)
        made.append(url)
    }
    return made
}

private func scratch() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// All four executables gate 8 launches are guarded -- both sides, benchmark
/// target and `BenchmarkTool`. Missing the baseline `BenchmarkTool` would leave
/// the process that does the timing unguarded.
@Test func theGuardCoversBothSidesAndBothExecutables() throws {
    let baseline = try scratch(), candidate = try scratch()
    defer {
        try? FileManager.default.removeItem(at: baseline)
        try? FileManager.default.removeItem(at: candidate)
    }
    let paths = EvalRunner.measuredBinaries(
        baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench")
    #expect(paths.count == 4)
    #expect(paths.map { $0.lastPathComponent } == ["Bench", "BenchmarkTool", "Bench", "BenchmarkTool"])
    #expect(paths[0].path.hasPrefix(baseline.path))
    #expect(paths[2].path.hasPrefix(candidate.path))

    _ = try fakeBinaries(baseline, target: "Bench", bytes: "baseline")
    _ = try fakeBinaries(candidate, target: "Bench", bytes: "candidate")
    let guardian = EvalRunner.MeasuredBinaryGuard(wrapping: NeverSampled(), binaries: paths)
    #expect(guardian.guardedCount == 4, "all four must be recorded")
    #expect(guardian.check() == nil, "an untouched set must pass")
}

/// THE ATTACK, in miniature and deterministic: the source sabotages the
/// BASELINE binary while the candidate sample runs. The very next sample
/// refuses, so the inflated binary is never measured.
@Test func aBinaryRewrittenMidMeasurementIsCaughtBeforeTheNextSample() throws {
    let baseline = try scratch(), candidate = try scratch()
    defer {
        try? FileManager.default.removeItem(at: baseline)
        try? FileManager.default.removeItem(at: candidate)
    }
    let victim = try fakeBinaries(baseline, target: "Bench", bytes: "honest baseline")[0]
    _ = try fakeBinaries(candidate, target: "Bench", bytes: "candidate")
    let paths = EvalRunner.measuredBinaries(
        baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench")

    let saboteur = SabotagingSource(after: 1) {
        try? "INFLATED baseline".write(to: victim, atomically: true, encoding: .utf8)
    }
    let guardian = EvalRunner.MeasuredBinaryGuard(wrapping: saboteur, binaries: paths)

    // Sample 1 is honest and delegates; the sabotage fires inside it.
    #expect(try guardian.sample(benchmark: "A", in: baseline, config: makeConfig()) == 100.0)
    // Sample 2 must refuse rather than measure the inflated binary.
    #expect(throws: EvalRunner.MeasuredBinaryTampered.self) {
        _ = try guardian.sample(benchmark: "A", in: candidate, config: makeConfig())
    }
    #expect(saboteur.delegated == 1, "no sample may be taken after the change")
    #expect(guardian.violation?.contains(victim.path) == true,
            "the refusal must NAME the binary: \(guardian.violation ?? "nil")")
}

/// PER SAMPLE, NOT PER EVAL. An attacker who sabotages, lets the slow baseline
/// samples run, and then puts the binary BACK would pass any start-and-end
/// comparison. The guard checks before every sample, so the restore comes too
/// late -- the refusal has already happened.
@Test func sabotageThenRestoreStillRefuses() throws {
    let baseline = try scratch(), candidate = try scratch()
    defer {
        try? FileManager.default.removeItem(at: baseline)
        try? FileManager.default.removeItem(at: candidate)
    }
    let victim = try fakeBinaries(baseline, target: "Bench", bytes: "honest")[0]
    _ = try fakeBinaries(candidate, target: "Bench", bytes: "candidate")
    let paths = EvalRunner.measuredBinaries(
        baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench")
    let guardian = EvalRunner.MeasuredBinaryGuard(wrapping: SabotagingSource(after: 99) {}, binaries: paths)

    try "INFLATED".write(to: victim, atomically: true, encoding: .utf8)
    #expect(guardian.check() != nil, "the change must be seen while it is in place")
    try "honest".write(to: victim, atomically: true, encoding: .utf8)
    #expect(guardian.check() == nil, """
        a restored binary hashes clean again -- which is exactly why the check has to happen \
        BEFORE EVERY SAMPLE and not once at the end
        """)
    // ...and a sample taken while it is inflated refuses, which is the point.
    try "INFLATED".write(to: victim, atomically: true, encoding: .utf8)
    #expect(throws: EvalRunner.MeasuredBinaryTampered.self) {
        _ = try guardian.sample(benchmark: "A", in: baseline, config: makeConfig())
    }
}

/// A DELETED binary is a violation too: removing the baseline executable
/// mid-measurement is as useful to an attacker as rewriting it.
@Test func aDeletedMeasuredBinaryIsAViolation() throws {
    let baseline = try scratch(), candidate = try scratch()
    defer {
        try? FileManager.default.removeItem(at: baseline)
        try? FileManager.default.removeItem(at: candidate)
    }
    let victim = try fakeBinaries(baseline, target: "Bench", bytes: "honest")[0]
    _ = try fakeBinaries(candidate, target: "Bench", bytes: "candidate")
    let paths = EvalRunner.measuredBinaries(
        baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench")
    let guardian = EvalRunner.MeasuredBinaryGuard(wrapping: NeverSampled(), binaries: paths)

    try FileManager.default.removeItem(at: victim)
    let offender = guardian.check()
    #expect(offender?.contains("the file is gone") == true, "\(offender ?? "nil")")
}

/// A repository with no built binaries at all records nothing and is inert --
/// which is what keeps every test that injects its own `MetricSource` working,
/// since those have no `.build/release` to guard.
@Test func theGuardIsInertWhenThereAreNoBinariesToGuard() throws {
    let baseline = try scratch(), candidate = try scratch()
    defer {
        try? FileManager.default.removeItem(at: baseline)
        try? FileManager.default.removeItem(at: candidate)
    }
    let guardian = EvalRunner.MeasuredBinaryGuard(
        wrapping: SabotagingSource(after: 99) {},
        binaries: EvalRunner.measuredBinaries(
            baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench"))
    #expect(guardian.guardedCount == 0)
    #expect(guardian.check() == nil)
    #expect(try guardian.sample(benchmark: "A", in: baseline, config: makeConfig()) == 100.0)
}

/// DETECTION IS NOT ENOUGH. The measured attack left an inflated baseline
/// binary behind and the next, entirely honest eval inherited it -- SwiftPM had
/// already recorded that binary as up to date for the restored source. Both
/// sides' measured binaries are therefore deleted on a refusal, so the next
/// build has to produce them again from verified sources.
@Test func aRefusalDiscardsTheMeasuredBinariesOnBothSides() throws {
    let baseline = try scratch(), candidate = try scratch()
    defer {
        try? FileManager.default.removeItem(at: baseline)
        try? FileManager.default.removeItem(at: candidate)
    }
    let b = try fakeBinaries(baseline, target: "Bench", bytes: "baseline")
    let c = try fakeBinaries(candidate, target: "Bench", bytes: "candidate")
    for url in b + c {
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    EvalRunner.discardMeasuredBinaries(
        baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench")
    for url in b + c {
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "\(url.lastPathComponent) survived a refusal")
    }
    // Idempotent: it also runs when there is nothing to remove.
    EvalRunner.discardMeasuredBinaries(
        baselineWorktree: baseline, candidateWorktree: candidate, benchmarkTarget: "Bench")
}

/// Gate 7 now RESTORES BEFORE it verifies, and that ordering is a bug fix, not
/// a preference. The previous order refused on a pre-restore `verify` -- which
/// runs before the repair whose whole job is to fix what it refused over -- so
/// tampering visible to `git status` bricked the run permanently: measured, an
/// eval and every eval after it returning `worktree_integrity` with the
/// worktree never repaired.
@Test func aWorktreeGitCanSeeIsDirtyIsRepairedRatherThanBrickingTheRun() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let worktree = try StateHome(repo: repo, env: env).worktreeURL(tag: "t")
    let helper = worktree.appendingPathComponent("Sources/Lib/Lib.swift")
    let original = try String(contentsOf: helper, encoding: .utf8)

    // Plainly dirty -- no index flags, nothing hidden. git sees it.
    try "public func f() -> Int { 99 }\n".write(to: helper, atomically: true, encoding: .utf8)
    #expect(try !Worktree.verify(at: worktree, expectedCommit: record.measurementCommit),
            "the premise: git can see this one")

    try makeInScopeCommit(repo, "an ordinary experiment")
    let v = try EvalRunner.run(repo: repo, env: env, source: CountingStub(), now: Date.init)
    #expect(v.reason != "worktree_integrity",
            "a dirty worktree must be repaired, not refused forever: \(v.reason ?? "nil")")
    // The verdict is quoted here too. When this failed intermittently alongside
    // `measurementCommitAdvancesAfterAKeep` under a full parallel suite, the
    // second assertion carried no diagnostics at all, so a red CI log said only
    // that two strings differed.
    #expect(try String(contentsOf: helper, encoding: .utf8) == original, """
        the repair did not happen: verdict=\(v.kind.rawValue) reason=\(v.reason ?? "nil") \
        warnings=\(v.warnings.map { String($0.prefix(300)) })
        """)
}

private final class CountingStub: MetricSource, @unchecked Sendable {
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double { 100.0 }
}

private func makeConfig() -> Config {
    Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench", benchmarks: ["A"],
           count: 10, alpha: 0.005, minEffectPct: 3.0, maxRegressPct: 3.0, timeoutSeconds: 600)
}
