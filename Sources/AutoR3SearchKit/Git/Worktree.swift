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
