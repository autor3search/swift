import Testing
import Foundation
@testable import AutoR3SearchKit

/// Fails the test if it is ever asked for a sample: proves gates rejected first.
private struct NeverCalledSource: MetricSource {
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        Issue.record("measurement ran even though a gate should have rejected first")
        return 0
    }
}

@Test func manifestEditIsRejectedBeforeAnythingIsMeasured() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    try "// swift-tools-version: 6.0\n// touched".write(
        to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                           ["-c", "git add -A && git commit -q -m touch"],
                           cwd: repo, env: nil, timeout: 60)
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "manifest_change_rejected")
    try FileManager.default.removeItem(at: repo)
}

@Test func configEditIsRejectedByHashMismatch() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    // Loosen the rules mid-run: raise max_regress_pct.
    let cfgURL = repo.appendingPathComponent(".autor3search/config.yaml")
    var text = try String(contentsOf: cfgURL, encoding: .utf8)
    text = text.replacingOccurrences(of: "max_regress_pct: 5.0", with: "max_regress_pct: 90.0")
    try text.write(to: cfgURL, atomically: true, encoding: .utf8)
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "config_hash_mismatch")
    try FileManager.default.removeItem(at: repo)
}

@Test func outOfScopeEditIsRejectedBeforeMeasuring() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    try "x".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                           ["-c", "git add -A && git commit -q -m out"],
                           cwd: repo, env: nil, timeout: 60)
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "out_of_scope")
    try FileManager.default.removeItem(at: repo)
}

/// Returns 100 for the original commit and 50 for anything kept afterwards.
private final class CommitAwareSource: MetricSource, @unchecked Sendable {
    let originalCommit: String
    var measuredAgainst: [String] = []
    init(originalCommit: String) { self.originalCommit = originalCommit }
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        let head = (try? Git(repo: worktree).head()) ?? ""
        measuredAgainst.append(head)
        return head == originalCommit ? 100.0 : 50.0
    }
}

@Test func measurementCommitAdvancesAfterAKeep() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)

    // A genuine win is kept; the measurement point must move to it.
    try makeInScopeCommit(repo, "fast")
    let kept = try git.head()
    _ = try EvalRunner.run(repo: repo, env: env,
                           source: CommitAwareSource(originalCommit: record.frozenCommit),
                           now: Date.init)
    let after = try BaselineRecord.load(home.baselineRecordURL(tag: "t"))
    #expect(after.measurementCommit == kept, "measurement baseline did not advance on KEEP")
    #expect(after.frozenCommit == record.frozenCommit,
            "the frozen commit must NEVER advance: moving the measurement point must not move the success criteria")
}

@Test func aNoOpAfterAWinDoesNotCoastToKeep() throws {
    // The publicly shipped bug: with a stale measurement point, a commit that only
    // adds a comment keeps winning on the strength of the earlier improvement.
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    try makeInScopeCommit(repo, "fast")
    let src = CommitAwareSource(originalCommit: record.frozenCommit)
    let win = try EvalRunner.run(repo: repo, env: env, source: src, now: Date.init)
    #expect(win.kind == .keep)

    // Now a pure no-op. Measured against the KEPT commit, both sides read 50.
    try makeInScopeCommit(repo, "fast // only a comment")
    let noop = try EvalRunner.run(repo: repo, env: env, source: src, now: Date.init)
    #expect(noop.kind != .keep, "a no-op coasted to KEEP on an earlier win")
    #expect(noop.reason == "no_significant_improvement")
    try FileManager.default.removeItem(at: repo)
}

// MARK: - The run claim

@Test func aSecondEvalRefusesWhileAnotherHoldsTheRunClaim() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)
    let claimURL = try home.runClaimURL(tag: "t")

    let held = try RunClaim.acquire(at: claimURL)
    #expect(RunClaim.isHeld(at: claimURL), "a held claim must read as held")

    // REFUSES, does not queue: it returns rather than blocking for the other
    // eval's full measurement session, and it never measures anything.
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "run_already_in_progress")

    held.release()
    #expect(!RunClaim.isHeld(at: claimURL), "releasing must actually free the claim")
    // And the claim is takeable again, so a refusal is not a permanent state.
    let second = try RunClaim.acquire(at: claimURL)
    second.release()
}

@Test func theRunClaimIsReleasedAfterAThrow() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    // No baseline for this repository: loading the baseline record throws, from
    // inside the region the claim covers.
    let home = try StateHome(repo: repo, env: env)
    let tag = try git.currentBranch()
    let claimURL = try home.runClaimURL(tag: tag)

    #expect(throws: (any Error).self) {
        _ = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    }
    #expect(!RunClaim.isHeld(at: claimURL),
            "a throw from inside the gate chain must still release the run claim")
}

/// Records every sample it is asked for, so warm-up samples are visible as
/// calls that happen outside the counted session.
private final class CountingSource: MetricSource, @unchecked Sendable {
    var worktrees: [String] = []
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        worktrees.append(worktree.standardizedFileURL.path)
        return 100.0
    }
}

@Test func aFullRunWarmsBothSidesAndReleasesItsRunClaim() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)
    let worktree = try home.worktreeURL(tag: "t").standardizedFileURL.path

    try makeInScopeCommit(repo, "no change in timing")
    let source = CountingSource()
    let v = try EvalRunner.run(repo: repo, env: env, source: source, now: Date.init)

    // Both sides read the same number, so nothing moved: DISCARD, no advance.
    #expect(v.kind == .discard)
    #expect(v.reason == "no_significant_improvement")

    // count: 10, one benchmark -> 20 counted samples, plus ONE discarded warm-up
    // sample on EACH side. Both sides, because the two binaries live in different
    // worktrees and each pays its own first-invocation cost.
    #expect(source.worktrees.count == 22,
            "expected 20 counted samples plus one discarded warm-up per side")
    #expect(source.worktrees.first == worktree, "the first warm-up must be the baseline side")
    #expect(source.worktrees.dropFirst().first == repo.standardizedFileURL.path,
            "the second warm-up must be the candidate side")

    #expect(!RunClaim.isHeld(at: try home.runClaimURL(tag: "t")),
            "a normal run must release its claim")

    // And the run was logged.
    let rows = try ResultsTSV.read(repo.appendingPathComponent("results.tsv"))
    #expect(rows.count == 1)
    #expect(rows.first?.experiment == 1)
    #expect(rows.first?.status == "discard")
}

@Test func warmUpTakesOneDiscardedSampleOnEachSideAndNeverThrows() throws {
    let counting = CountingSource()
    let config = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench",
                        benchmarks: ["A", "B"], count: 10, alpha: 0.05,
                        minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
    let baseline = URL(fileURLWithPath: "/tmp/baseline-side")
    let candidate = URL(fileURLWithPath: "/tmp/candidate-side")
    let quiet = EvalRunner.warmUp(benchmarks: config.benchmarks, baselineWorktree: baseline,
                                  candidateWorktree: candidate, source: counting, config: config)
    #expect(quiet.isEmpty)
    #expect(counting.worktrees == [baseline.path, candidate.path, baseline.path, candidate.path],
            "one discarded sample per benchmark per side, baseline first")

    // A warm-up that fails is a warning, never a thrown run: the counted session
    // immediately afterwards runs the same code and surfaces any real problem.
    struct AlwaysFails: MetricSource {
        func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
            throw MetricError.noPercentileTable("")
        }
    }
    let noisy = EvalRunner.warmUp(benchmarks: ["A"], baselineWorktree: baseline,
                                 candidateWorktree: candidate, source: AlwaysFails(), config: config)
    #expect(noisy.count == 2)
}

// MARK: - A refused restore

@Test func aRefusedRestoreIsFatalNeverRetriedAndRecordedAsTainted() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)

    // Plant a symlink where a frozen file belongs: the unattended-arbitrary-
    // file-overwrite attack `FrozenSnapshot.restore` refuses.
    let decoy = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("decoy-\(UUID().uuidString).swift")
    try "// decoy\n".write(to: decoy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: decoy) }
    let frozen = repo.appendingPathComponent("Tests/LibTests/LibTests.swift")
    try FileManager.default.removeItem(at: frozen)
    try FileManager.default.createSymbolicLink(at: frozen, withDestinationURL: decoy)

    // NeverCalledSource: a refusal stops the run before anything is measured.
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "frozen_restore_refused",
            "a restore refusal must be recorded distinctly, not as an ordinary gate failure")

    // Nothing was written through the link.
    let decoyText = try String(contentsOf: decoy, encoding: .utf8)
    #expect(decoyText == "// decoy\n")

    // Recorded as tainted.
    let taintURL = RunTaint.url(runDir: try home.runDir(tag: "t"))
    #expect(FileManager.default.fileExists(atPath: taintURL.path))

    // NEVER RETRIED. The refusal aborts the whole restore and the run stays
    // refused, so an attacker racing the TOCTOU window gets roughly one attempt
    // per run instead of an unbounded number across an overnight loop.
    let again = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(again.kind == .fail)
    #expect(again.reason == "run_tainted")

    // Clearing the marker by hand is the only way back.
    try FileManager.default.removeItem(at: taintURL)
    #expect(RunTaint.pending(runDir: try home.runDir(tag: "t")) == nil)
}

// MARK: - results.tsv numbering

@Test func experimentNumbersNeverRepeatAfterTheLogIsEditedByHand() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("results.tsv")

    #expect(EvalRunner.nextExperimentNumber(at: url) == 1, "a missing log starts at 1")

    for n in 1...3 {
        try ResultsTSV.append(ResultsRow(
            experiment: n, commit: "c\(n)", status: "discard", score: 1.0, reason: "",
            unsafeCount: 0, toolVersion: "0.1.0", timestamp: "t"), to: url)
    }
    #expect(EvalRunner.nextExperimentNumber(at: url) == 4)

    // Someone deletes a row from the middle. `count + 1` would hand out 3 again,
    // producing two different experiments with the same number in one file.
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    try (lines[0] + "\n" + lines[1] + "\n" + lines[3] + "\n").write(
        to: url, atomically: true, encoding: .utf8)
    #expect(EvalRunner.nextExperimentNumber(at: url) == 4,
            "deleting a row must not make the next experiment reuse a number still in the file")

    // Truncated to nothing: there is no history left to be consistent with, and
    // the commit SHA in each row, not this column, is what identifies a run.
    try Data().write(to: url)
    #expect(EvalRunner.nextExperimentNumber(at: url) == 1)
}
