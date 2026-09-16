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

// WHY THE TWO HELPERS BELOW EXIST, AND WHY A BARE `#expect(!RunClaim.isHeld(...))`
// IMMEDIATELY AFTER A RELEASE IS NOT A CORRECT ASSERTION IN *THIS* PROCESS.
//
// This was a real, recurring flake:
//
//     ✘ aSecondEvalRefusesWhileAnotherHoldsTheRunClaim()
//       EvalRunnerTests.swift:127:5: Expectation failed: !RunClaim.isHeld(at: claimURL)
//
// The claim is an advisory `flock` held against the OPEN FILE DESCRIPTION, and
// the kernel drops it when the LAST descriptor referring to that description is
// closed. `fork` duplicates the whole descriptor table, so a child born while
// this test holds its claim shares the very same open file description --
// including its lock. `O_CLOEXEC` closes the copy, but `O_CLOEXEC` acts at
// EXEC, not at FORK, so for the width of one fork-to-exec window the lock has
// TWO holders and the original holder's own `close` does not drop it.
//
// swift-testing runs the whole suite in ONE process, in parallel, and most of
// the other tests in it spawn `git`, `swift build` and `swift package describe`
// through `POSIXSpawn`. Every one of those spawns briefly duplicates THIS
// test's claim descriptor, no matter how well isolated the test's repository
// path and `AUTOR3SEARCH_SWIFT_STATE_HOME` are: the descriptor is inherited by
// fd number, not by path. So a claim this test has genuinely released can keep
// reading as held for about a millisecond, and the assertion above fails.
//
// Measured, in this suite, with a 1500-iteration acquire/release loop and N
// background threads doing nothing but `Subprocess.run(git, ["--version"])`
// (docs/run-log.md carries the full output):
//
//     spawners=0  stillHeldAfterRelease=0   reacquireThrew=0   mechanismBreaks=0
//     spawners=1  stillHeldAfterRelease=8   reacquireThrew=4   mechanismBreaks=0
//     spawners=3  stillHeldAfterRelease=36  reacquireThrew=21  mechanismBreaks=0
//     spawners=6  stillHeldAfterRelease=54  reacquireThrew=45  mechanismBreaks=0
//
// `mechanismBreaks` -- two acquires granted at once -- was ZERO in all 6000
// iterations. That is the part that matters: the window is strictly
// CONSERVATIVE. It can make a free claim look busy for a millisecond; it can
// never let two evals measure at the same time, which is the only thing the
// claim exists to prevent. The mechanism is sound; the assertion was not.
//
// The helpers therefore wait, briefly, instead of sampling once. They do NOT
// weaken what is being asserted: a claim that is never released stays held
// forever, so a genuinely broken `release()` still fails the test -- it just
// takes `budget` seconds to say so. (Mutation-checked: with the `release()`
// body in `RunClaim` commented out, the test below fails.)

/// Whether `url`'s claim reads as free within `budget`.
private func claimBecomesFree(_ url: URL, within budget: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(budget)
    while true {
        if !RunClaim.isHeld(at: url) { return true }
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: 0.002)
    }
}

/// Takes the claim, retrying ONLY `alreadyHeld` and only for `budget`.
///
/// Any other error is rethrown at once: this exists to absorb the fork-to-exec
/// window described above, not to paper over a claim that cannot be opened.
private func acquireClaim(_ url: URL, within budget: TimeInterval = 5) throws -> RunClaim {
    let deadline = Date().addingTimeInterval(budget)
    while true {
        do {
            return try RunClaim.acquire(at: url)
        } catch RunClaimError.alreadyHeld {
            if Date() >= deadline { throw RunClaimError.alreadyHeld(path: url.path, holder: "") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

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
    #expect(claimBecomesFree(claimURL), "releasing must actually free the claim")
    // And the claim is takeable again, so a refusal is not a permanent state.
    let second = try acquireClaim(claimURL)
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
    #expect(claimBecomesFree(claimURL),
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

    #expect(claimBecomesFree(try home.runClaimURL(tag: "t")),
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

// MARK: - The working tree must be clean

@Test func aDirtyWorkingTreeIsRefusedBeforeAnythingIsMeasured() throws {
    // Gate 1 diffs COMMITS; gates 5, 6 and 8 build and measure the WORKING TREE. An
    // uncommitted, out-of-scope edit would be compiled into the candidate binary and
    // measured while no gate ever looked at it -- and because the pinned worktree is a
    // checkout of a commit, it would manufacture a fresh "win" on every later eval,
    // credited to commits that do not contain it.
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    // Out of scope (scope is Sources/**), and deliberately NOT committed, so the scope
    // gate has nothing to look at.
    try "helper data the benchmark reads\n".write(
        to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    // NeverCalledSource records an issue if it is ever sampled.
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "dirty_working_tree")
    #expect(v.warnings.first?.contains("a.txt") == true,
            "the refusal must name what is dirty, so the operator can act on it")

    // Committing it makes it visible to the scope gate, which then judges it on its
    // merits -- out of scope, and refused for that reason instead.
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                           ["-c", "git add -A && git commit -q -m helper"],
                           cwd: repo, env: nil, timeout: 60)
    let committed = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(committed.reason == "out_of_scope")
}

// MARK: - A refused restore

@Test func aRefusedRestoreIsFatalNeverRetriedAndRecordedAsTainted() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    // Widen scope to "**" BEFORE baseline, so the scope gate does not reject the
    // committed symlink first and the run actually reaches gate 3. The config is
    // committed before baseline hashes it, so gate 2 is satisfied too.
    let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
    var text = try String(contentsOf: configURL, encoding: .utf8)
    text = text.replacingOccurrences(of: "  - Sources/**", with: "  - '**'")
    try text.write(to: configURL, atomically: true, encoding: .utf8)
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                           ["-c", "git add -A && git commit -q -m scope"],
                           cwd: repo, env: nil, timeout: 60)

    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)

    // Plant a symlink where a frozen file belongs: the unattended-arbitrary-
    // file-overwrite attack `FrozenSnapshot.restore` refuses. Committed, so the
    // tree is clean and gate 2b is not what answers.
    let decoy = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("decoy-\(UUID().uuidString).swift")
    try "// decoy\n".write(to: decoy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: decoy) }
    let frozen = repo.appendingPathComponent("Tests/LibTests/LibTests.swift")
    try FileManager.default.removeItem(at: frozen)
    try FileManager.default.createSymbolicLink(at: frozen, withDestinationURL: decoy)
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                           ["-c", "git add -A && git commit -q -m link"],
                           cwd: repo, env: nil, timeout: 60)

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

// =========================================================================
// MARK: - Gate 2a: manifest integrity by hash, not by path
// =========================================================================
//
// Gate 1 asks git which PATHS changed; gate 2b asks git whether the tree is
// clean. Both read the index, and an agent with a shell owns the index. These
// tests perform the REAL attack -- `git update-index --assume-unchanged` -- not
// a simulation of it, and assert that the harness now rejects it.

/// THE BYPASS. `--assume-unchanged` tells git to stop looking at the file's
/// working-tree state; the manifest can then be rewritten with `-Ounchecked`
/// while `git status --porcelain` stays EMPTY and `git diff frozenCommit HEAD`
/// names only the in-scope source file. `swift build` reads the file on disk,
/// so the candidate is compiled with bounds checking OFF -- winning the
/// measurement without anyone writing faster code, which is precisely what this
/// tool exists to prevent.
///
/// The test asserts the git-level premise first. Without those two assertions
/// it would be impossible to tell a working gate from a bypass that silently
/// stopped working (e.g. if a future git refused `--assume-unchanged`), and a
/// test that passes for the wrong reason is worse than no test.
@Test func assumeUnchangedManifestBypassIsRejectedByHash() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let sh = URL(fileURLWithPath: "/bin/sh")

    // Hide Package.swift from git, then rewrite it with an unsafe compiler flag.
    let hide = try Subprocess.run(
        sh, ["-c", "git update-index --assume-unchanged Package.swift"],
        cwd: repo, env: nil, timeout: 60)
    #expect(hide.exitCode == 0, "\(hide.stderr)")

    let manifest = repo.appendingPathComponent("Package.swift")
    let original = try String(contentsOf: manifest, encoding: .utf8)
    let tampered = original.replacingOccurrences(
        of: ".target(name: \"Lib\")",
        with: ".target(name: \"Lib\", swiftSettings: [.unsafeFlags([\"-Ounchecked\"])])")
    #expect(tampered != original, "the fixture manifest changed shape; the rewrite matched nothing")
    try tampered.write(to: manifest, atomically: true, encoding: .utf8)

    // A perfectly ordinary, in-scope, committed source change rides along.
    try makeInScopeCommit(repo, "innocent looking")

    // THE PREMISE, asserted rather than assumed: both path-based gates are blind.
    let status = try Subprocess.run(sh, ["-c", "git status --porcelain"],
                                    cwd: repo, env: nil, timeout: 60)
    #expect(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the bypass did not work -- gate 2b would have caught this anyway: \(status.stdout)")
    let changed = try Git(repo: repo).changedPaths(since: record.frozenCommit)
    #expect(!changed.contains("Package.swift"),
            "the bypass did not work -- gate 1 would have caught this anyway: \(changed)")
    #expect(try String(contentsOf: manifest, encoding: .utf8).contains("-Ounchecked"),
            "the tampered manifest must actually be the one on disk")

    // And yet the hash gate sees it.
    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "manifest_change_rejected", "got \(v.reason ?? "nil")")
}

/// The same door, for the lockfile, in the `absentPin` case. `baseline`
/// recorded that this package produces no `Package.resolved`; one APPEARING
/// changes the dependency set the candidate builds against. A lockfile named in
/// `.gitignore` is invisible to `git status`, so gate 2b sees a clean tree --
/// which is exactly the state `doctor` used to recommend creating.
@Test func aLockfileAppearingWhereBaselineRecordedNoneIsRejected() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let sh = URL(fileURLWithPath: "/bin/sh")

    // The ignore rule has to predate the freeze. Committing it AFTER baseline
    // would put `.gitignore` in the frozenCommit..HEAD diff, and `.gitignore`
    // is not in `scope` -- gate 1 would answer `out_of_scope` and this test
    // would pass without ever reaching the gate it exists to bind. (Observed:
    // it did exactly that on the first attempt.)
    let gitignore = repo.appendingPathComponent(".gitignore")
    try (try String(contentsOf: gitignore, encoding: .utf8) + "Package.resolved\n")
        .write(to: gitignore, atomically: true, encoding: .utf8)
    let commit = try Subprocess.run(sh, ["-c", "git add -- .gitignore && git commit -q -m ignore"],
                                    cwd: repo, env: nil, timeout: 60)
    #expect(commit.exitCode == 0, "\(commit.stderr)")

    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(record.packageResolvedSHA256 == Lockfile.absentPin,
            "the dependency-free fixture must record absence, not a hash")

    // Now the lockfile arrives, invisibly.
    try "{ \"pins\": [], \"version\": 3 }\n".write(
        to: Lockfile.url(in: repo), atomically: true, encoding: .utf8)
    try makeInScopeCommit(repo, "innocent looking")

    let status = try Subprocess.run(sh, ["-c", "git status --porcelain"],
                                    cwd: repo, env: nil, timeout: 60)
    #expect(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the ignored lockfile must be invisible to gate 2b: \(status.stdout)")

    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "manifest_change_rejected", "got \(v.reason ?? "nil")")
}

// =========================================================================
// MARK: - Gate 2a, part 2: EVERY manifest, not just the two at the root
// =========================================================================

/// Adds a nested package manifest to `repo` and commits it, returning its
/// relative path. `Sub/` is not under any target's path, so SwiftPM ignores it
/// for build purposes -- but `ScopeGate.isManifestPath` recognises it, SwiftPM
/// would honour it if `Sub` were ever referenced, and it is exactly the file
/// the root-only hash check could not see.
private func addNestedManifest(_ repo: URL, body: String) throws -> String {
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    try body.write(to: repo.appendingPathComponent("Sub/Package.swift"),
                   atomically: true, encoding: .utf8)
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                               ["-c", "git add -- Sub && git commit -q -m nested"],
                               cwd: repo, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "\(r.stderr)")
    return "Sub/Package.swift"
}

/// THE NESTED BYPASS, with `--skip-worktree` rather than `--assume-unchanged`.
///
/// Two things at once, both of which were holes after round 2:
///
/// 1. Gate 2a hashed only the ROOT manifests. `ScopeGate.isManifestPath`
///    catches `Sub/Package.swift` BY PATH -- and defeating path accounting is
///    the entire attack -- so a repository with a nested package still had the
///    `-Ounchecked` route open, and the project's "rejected outright
///    regardless of scope" claim was true only at the root.
/// 2. `--skip-worktree` was asserted in prose and never run. Same mechanism as
///    `--assume-unchanged`, but untested is untested.
///
/// The git-level premise is asserted first, so this cannot pass for the wrong
/// reason if a future git stops honouring the flag.
@Test func skipWorktreeNestedManifestBypassIsRejectedByHash() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let sh = URL(fileURLWithPath: "/bin/sh")

    // The nested manifest must exist at frozenCommit, so baseline inventories it.
    let nested = try addNestedManifest(repo, body: """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Sub", targets: [.target(name: "Sub")])
        """)
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(record.manifestSHA256?[nested] != nil,
            "baseline must have inventoried the nested manifest; got \(record.manifestSHA256 ?? [:])")

    // Hide it from git with the OTHER index flag, then rewrite it unsafely.
    let hide = try Subprocess.run(sh, ["-c", "git update-index --skip-worktree -- \(nested)"],
                                  cwd: repo, env: nil, timeout: 60)
    #expect(hide.exitCode == 0, "\(hide.stderr)")
    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Sub",
            targets: [.target(name: "Sub", swiftSettings: [.unsafeFlags(["-Ounchecked"])])]
        )
        """.write(to: repo.appendingPathComponent(nested), atomically: true, encoding: .utf8)

    try makeInScopeCommit(repo, "innocent looking")

    // THE PREMISE: --skip-worktree really does blind both path-based gates.
    let status = try Subprocess.run(sh, ["-c", "git status --porcelain"],
                                    cwd: repo, env: nil, timeout: 60)
    #expect(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, """
        --skip-worktree did not hide the edit, so gate 2b would have caught this anyway and this \
        test proves nothing about gate 2a: \(status.stdout)
        """)
    let changed = try Git(repo: repo).changedPaths(since: record.frozenCommit)
    #expect(!changed.contains(nested), """
        --skip-worktree did not hide the edit from the commit diff, so gate 1 would have caught \
        this anyway: \(changed)
        """)
    #expect(try String(contentsOf: repo.appendingPathComponent(nested), encoding: .utf8)
                .contains("-Ounchecked"),
            "the tampered nested manifest must actually be the one on disk")

    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "manifest_change_rejected", "got \(v.reason ?? "nil")")
}

/// A manifest that APPEARS is worth as much to an attacker as one that is
/// edited: no recorded hash can mismatch for a file that had no hash. SwiftPM
/// honours a nested manifest that was not there before, and `.gitignore`ing it
/// keeps it out of `git status` entirely.
@Test func aManifestAppearingWhereBaselineRecordedNoneIsRejected() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let sh = URL(fileURLWithPath: "/bin/sh")

    // Ignore Sub/ BEFORE the freeze, so its arrival leaves a clean tree and
    // does not put .gitignore (which is out of scope) into the commit diff.
    let gitignore = repo.appendingPathComponent(".gitignore")
    try (try String(contentsOf: gitignore, encoding: .utf8) + "Sub/\n")
        .write(to: gitignore, atomically: true, encoding: .utf8)
    let commit = try Subprocess.run(sh, ["-c", "git add -- .gitignore && git commit -q -m ignore"],
                                    cwd: repo, env: nil, timeout: 60)
    #expect(commit.exitCode == 0, "\(commit.stderr)")

    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(record.manifestSHA256?["Sub/Package.swift"] == nil,
            "the fixture must start with no nested manifest")

    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Sub", targets: [.target(name: "Sub")])
        """.write(to: repo.appendingPathComponent("Sub/Package.swift"),
                  atomically: true, encoding: .utf8)
    try makeInScopeCommit(repo, "innocent looking")

    let status = try Subprocess.run(sh, ["-c", "git status --porcelain"],
                                    cwd: repo, env: nil, timeout: 60)
    #expect(status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the ignored nested manifest must be invisible to gate 2b: \(status.stdout)")

    let v = try EvalRunner.run(repo: repo, env: env, source: NeverCalledSource(), now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "manifest_change_rejected", "got \(v.reason ?? "nil")")
}

/// MIGRATION. A record written before the inventory existed decodes with
/// `manifestSHA256 == nil`. That run is unprotected against every nested-
/// manifest route above, so it is REFUSED -- "no record of its manifests" must
/// not be read as "no manifests to check", which is the empty-inventory
/// mistake in a new costume.
@Test func aBaselineWithNoManifestInventoryIsRefusedRatherThanWavedThrough() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    var stale = record
    stale.manifestSHA256 = nil
    #expect(EvalRunner.manifestInventoryFailure(repo: repo, record: stale)?.reason
                == "baseline_predates_manifest_inventory")
    // An EMPTY inventory is a different thing and must not be confused with a
    // missing one: it means "baseline looked and found none", which is only
    // ever true for a package with no manifests at all -- and any appearance
    // is then still caught.
    var empty = record
    empty.manifestSHA256 = [:]
    #expect(empty.manifestSHA256 != nil)
    #expect(EvalRunner.manifestInventoryFailure(repo: repo, record: empty)?.reason
                == "manifest_change_rejected",
            "an empty inventory must still flag the root Package.swift as having appeared")
}

/// A `BaselineRecord` written before this field existed has no
/// `manifestSHA256` key at all. It must still DECODE -- refusing to read the
/// record would turn a recoverable "re-baseline" into an unreadable run
/// directory -- and must decode as `nil`, not as an empty dictionary.
@Test func anOlderBaselineRecordStillDecodesWithANilInventory() throws {
    let json = Data("""
        {"tag":"t","frozenCommit":"a","measurementCommit":"a","configSHA256":"c",
         "packageSwiftSHA256":"p","packageResolvedSHA256":"r","toolVersion":"0.1.0"}
        """.utf8)
    let decoded = try JSONDecoder().decode(BaselineRecord.self, from: json)
    #expect(decoded.manifestSHA256 == nil)
}

/// The inventory must see what `swift build` sees and nothing else. `.build`
/// holds every dependency's checkout, each with its own `Package.swift`;
/// inventorying those would make every eval a rejection the moment SwiftPM
/// touched its cache.
@Test func manifestInventoryFindsNestedManifestsAndSkipsBuildAndGit() throws {
    let (repo, _) = try makeGitFixture()
    defer { try? FileManager.default.removeItem(at: repo) }
    do {
        _ = try addNestedManifest(repo, body: "// swift-tools-version: 6.0\n")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".build/checkouts/dep"), withIntermediateDirectories: true)
        try "// a dependency's own manifest\n".write(
            to: repo.appendingPathComponent(".build/checkouts/dep/Package.swift"),
            atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".swiftpm/configuration"), withIntermediateDirectories: true)
        try "{}\n".write(to: repo.appendingPathComponent(".swiftpm/configuration/mirrors.json"),
                         atomically: true, encoding: .utf8)
        try "// version specific\n".write(
            to: repo.appendingPathComponent("Package@swift-6.0.swift"),
            atomically: true, encoding: .utf8)

        let inventory = try BaselineRunner.manifestInventory(repo: repo)
        #expect(inventory["Package.swift"] != nil)
        #expect(inventory["Sub/Package.swift"] != nil, "a nested manifest must be inventoried")
        #expect(inventory["Package@swift-6.0.swift"] != nil,
                "SwiftPM substitutes this for Package.swift when it matches the toolchain")
        #expect(inventory[".swiftpm/configuration/mirrors.json"] != nil,
                "mirrors.json can redirect a dependency to an entirely different source")
        #expect(inventory[".build/checkouts/dep/Package.swift"] == nil,
                "dependencies' own manifests must not be inventoried")
        // Ordinary source that merely looks manifest-ish stays editable.
        #expect(inventory["Sources/Lib/Lib.swift"] == nil)
    }
}

/// The other direction, and the reason the gate is safe to add: an untouched
/// manifest must pass it. Called directly rather than through a whole `eval` so
/// this stays a pure assertion about the gate itself.
@Test func manifestIntegrityPassesAnUntouchedRepository() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(EvalRunner.manifestIntegrityFailure(repo: repo, record: record) == nil)

    // A deleted manifest is a MISMATCH, not a thrown harness error: the
    // experiment is rejected with a scored verdict and a results.tsv row.
    try FileManager.default.removeItem(at: repo.appendingPathComponent("Package.swift"))
    let failure = EvalRunner.manifestIntegrityFailure(repo: repo, record: record)
    #expect(failure?.reason == "manifest_change_rejected")
    #expect(failure?.detail.contains("missing") == true)
}
