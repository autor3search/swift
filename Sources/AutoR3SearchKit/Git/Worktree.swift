import Foundation

/// The pinned, detached baseline worktree the measurement harness measures
/// against. It lives outside the repository under test (see `StateHome`) so
/// an AI agent editing the repository cannot influence its own baseline.
///
/// After every KEEP, `repoint` moves this worktree's HEAD to the newly kept
/// commit — the next experiment is measured against what was just kept, not
/// against where the run started. Skipping that advance is exactly the bug
/// this type exists to prevent: one real win would let every later no-op
/// coast to KEEP forever, because "baseline" would silently stay frozen at
/// the run's starting commit instead of tracking the accepted improvements.
public enum Worktree {
    /// Registers a detached worktree at `commit`, outside the repository,
    /// with its own build directory.
    public static func add(git: Git, at url: URL, commit: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try git.run(["worktree", "add", "--detach", "--force", url.path, commit])
    }

    /// Called after every KEEP. The measurement point moves; the frozen
    /// point (the scope gate's comparison base) never does — that
    /// distinction lives in `BaselineRecord`, not here.
    ///
    /// `checkout --force` discards tracked modifications but leaves
    /// untracked files behind, and `verify` (below) folds cleanliness into
    /// its verdict — so any untracked residue left over from a previous run
    /// would make `verify` fail forever, even at the correct commit.
    /// `clean -fd` removes that residue. Deliberately `-fd`, NOT `-fdx`:
    /// `-x` also deletes files covered by `.gitignore`, and Task 16 keeps a
    /// warmed `.build` directory (ignored, not tracked) inside this pinned
    /// worktree specifically so eval doesn't pay a cold Swift build on
    /// every measurement. `-fd` clears untracked-but-not-ignored residue
    /// and leaves ignored build output — the warm cache — alone.
    public static func repoint(git: Git, at url: URL, to commit: String) throws {
        try git.run(["checkout", "--detach", "--force", commit], cwd: url)
        try git.run(["clean", "-fd"], cwd: url)
    }

    /// Whether the worktree is exactly `expectedCommit` AND untouched: the
    /// pin the measurement harness actually depends on.
    ///
    /// DECISION (documented for Task 17's worktree-integrity gate): `verify`
    /// itself checks cleanliness, not just HEAD identity. A worktree at the
    /// right commit but with local modifications — dirty-but-correct-HEAD —
    /// is NOT a verified pin: a previous run's leftover edit, a stray build
    /// artifact rewritten in place, or partial tampering could sit at the
    /// right commit while still changing what gets measured. Folding
    /// cleanliness into `verify` means the integrity gate is a single call
    /// that fails closed by construction, rather than depending on every
    /// caller remembering to additionally call `isClean`. `isClean(at:)`
    /// remains available separately so a caller (or a diagnostic message)
    /// can distinguish *why* verification failed — wrong commit vs. dirty
    /// tree — but the pass/fail decision itself should be made from
    /// `verify` alone.
    ///
    /// This is a semantic change from the brief's Step 3 reference
    /// implementation, which compared HEAD only. The signature is
    /// unchanged; the behavior is stricter.
    public static func verify(at url: URL, expectedCommit: String) throws -> Bool {
        let worktreeGit = Git(repo: url)
        guard let head = try? worktreeGit.head() else { return false }
        guard head == expectedCommit else { return false }
        return (try? worktreeGit.isClean()) == true
    }

    /// Paths in this worktree's index carrying `--assume-unchanged` or
    /// `--skip-worktree`, together with the one-letter tag `git ls-files -v`
    /// gave them.
    ///
    /// WHY `verify` IS NOT ENOUGH, and this is a live bypass, not a
    /// hypothetical. `verify` asks `git status`, and the agent can reach this
    /// worktree with a shell:
    ///
    ///     git -C <worktree> update-index --assume-unchanged Sources/.../Helper.swift
    ///     <edit it: the benchmark's workload 1750 -> 17500>
    ///
    /// `git status` is then empty, `verify` returns true, and the baseline-side
    /// `swift build` compiles the edit -- so the BASELINE gets slower and a
    /// comment-only commit measures as a win. Measured: `rc 0, keep,
    /// ratio 0.09997`.
    ///
    /// `ls-files -v` prints a per-path tag: `H` for an ordinary cached entry,
    /// `S` for skip-worktree, and a LOWERCASE letter for any entry marked
    /// assume-unchanged. Both flags are what hide the edit, and they are read
    /// straight out of the index rather than inferred, so this sees them even
    /// though `status` does not.
    ///
    /// Reported AND repaired rather than merely refused -- see
    /// `restoreToPin` for why.
    public static func indexFlaggedPaths(at url: URL) throws -> [(tag: Character, path: String)] {
        let git = Git(repo: url)
        let output = try git.run(["ls-files", "-v"])
        var flagged: [(tag: Character, path: String)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first, line.count > 2 else { continue }
            // Lowercase => assume-unchanged (of any state); "S" => skip-worktree.
            guard tag.isLowercase || tag == "S" else { continue }
            flagged.append((tag: tag, path: String(line.dropFirst(2))))
        }
        return flagged
    }

    /// Puts this worktree back to exactly `commit`, defeating the index flags
    /// above, and returns the flagged paths it had to clear (empty on a clean
    /// worktree).
    ///
    /// THE ORDER MATTERS AND WAS MEASURED. `git checkout --force` alone
    /// restores a file hidden with `--assume-unchanged`, but NOT one hidden
    /// with `--skip-worktree`: verified directly, the tampered content
    /// survived a forced checkout untouched. So the flags are cleared FIRST,
    /// by path, and only then is the checkout forced.
    ///
    /// REPAIR, NOT REFUSAL. This worktree is harness-owned state whose correct
    /// contents are known exactly -- it is a checkout of `commit` and nothing
    /// else -- so restoring it is always the right answer and is what
    /// `FrozenSnapshot.restore` already does for the frozen files. Refusing
    /// instead would hand the agent a one-line denial of service: touch the
    /// worktree, and every experiment for the rest of the night fails. The
    /// caller still surfaces the cleared paths as a warning, so a human sees
    /// that it happened.
    ///
    /// Cheap enough to run unconditionally before every measurement: a
    /// `checkout --force` to the commit already checked out rewrites nothing
    /// and leaves mtimes alone, so the warm `.build` stays valid and the
    /// incremental rebuild that follows is unaffected. `clean -fd` (never
    /// `-fdx`) removes untracked residue and leaves that warm cache alone.
    @discardableResult
    public static func restoreToPin(git: Git, at url: URL, to commit: String) throws
        -> [(tag: Character, path: String)] {
        let flagged = (try? indexFlaggedPaths(at: url)) ?? []
        if !flagged.isEmpty {
            let worktreeGit = Git(repo: url)
            let paths = flagged.map(\.path)
            // TWO SEPARATE INVOCATIONS, AND THIS IS NOT STYLE. Measured
            // directly against git: passing `--no-assume-unchanged` and
            // `--no-skip-worktree` together in ONE `update-index` call exits 0
            // and does NOTHING -- the entry keeps its `S` tag. Each flag alone
            // works. A silent success that changes nothing is exactly the
            // failure mode this project exists to catch, and it is why the
            // post-condition below is checked rather than assumed: the first
            // version of this function combined the flags, reported "the flags
            // were cleared" in a warning, and let the attack through with
            // `rc 0, keep, ratio 0.10000570`.
            for flag in ["--no-assume-unchanged", "--no-skip-worktree"] {
                // In chunks: a worktree with thousands of flagged paths would
                // otherwise build one enormous argv.
                for start in stride(from: 0, to: paths.count, by: 256) {
                    let chunk = Array(paths[start..<min(start + 256, paths.count)])
                    _ = try? worktreeGit.run(["update-index", flag, "--"] + chunk)
                }
            }
            let remaining = (try? indexFlaggedPaths(at: url)) ?? []
            guard remaining.isEmpty else {
                throw GitError.command(
                    "update-index --no-assume-unchanged/--no-skip-worktree",
                    0,
                    """
                    \(remaining.count) path(s) are still marked assume-unchanged or \
                    skip-worktree after being cleared: \
                    \(remaining.map { "\($0.tag) \($0.path)" }.prefix(20).joined(separator: ", ")). \
                    A forced checkout does not restore a skip-worktree path, so the worktree \
                    cannot be established as a clean checkout of \(commit).
                    """)
            }
        }
        try repoint(git: git, at: url, to: commit)
        // POST-CONDITION, checked rather than assumed. With the index flags
        // cleared, `git status` is honest again -- they were the reason it was
        // lying -- so `verify` is meaningful here in a way it was not before
        // the restore. Failing closed: the caller turns this into a refusal,
        // because the baseline side is what every ratio is divided by.
        guard try verify(at: url, expectedCommit: commit) else {
            throw GitError.command(
                "checkout --detach --force \(commit)", 0,
                "the worktree is still not a clean checkout of \(commit) after being restored")
        }
        return flagged
    }

    /// Whether the worktree has no local modifications, independent of which
    /// commit it is on. Useful for diagnosing *why* `verify` failed. See
    /// `verify`'s doc comment for the decision to also fold this check into
    /// `verify` itself.
    public static func isClean(at url: URL) throws -> Bool {
        try Git(repo: url).isClean()
    }

    /// Destructive: force-removes the worktree registration and its files.
    /// Only ever targets `url` — callers own the fixture/production
    /// lifecycle and must not point this at anything else.
    public static func remove(git: Git, at url: URL) throws {
        try git.run(["worktree", "remove", "--force", url.path])
    }
}
