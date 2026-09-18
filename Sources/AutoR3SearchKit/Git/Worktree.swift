import Foundation
import Crypto

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
    /// Every tracked path at `commit` whose bytes ON DISK do not hash to the
    /// blob git recorded for it, plus anything missing.
    ///
    /// WHY `verify` IS NOT A POST-CONDITION. `verify` asks `git status`, and
    /// `git status` can be made to lie about content, not merely about flags. A
    /// `.gitattributes` entry plus a `filter.<driver>` in `.git/config` -- both
    /// agent-writable -- runs a SMUDGE filter during the harness's own
    /// `checkout --force` and a CLEAN filter when git compares the result back.
    /// Measured directly:
    ///
    /// ```
    /// after forced checkout of a modified file: count = 17500
    /// the commit actually holds:                count = 1750
    /// git status --porcelain:                   (empty -- "clean")
    /// hash-object --no-filters: f0b02a86...   commit blob: cc57109a...
    /// ```
    ///
    /// Denying hooks does not touch that: it is a different piece of code the
    /// harness runs. So the post-condition stops asking git whether the tree is
    /// clean and computes the answer itself: `ls-tree` gives the blob id for
    /// every path at `commit` (an id, not a judgement -- it comes from the
    /// commit object, which is content-addressed and cannot be rewritten
    /// without changing the SHA the baseline record pins), and each file's own
    /// bytes are hashed here with git's blob rule, `sha1("blob <len>\0" +
    /// bytes)`. No index, no filters, no status.
    ///
    /// Symlinks (mode 120000) hash their TARGET STRING, which is what git
    /// stores, so a re-aimed link is a mismatch. Gitlinks (mode 160000,
    /// submodules) are skipped: their content is another repository, not a file
    /// in this one.
    public static func contentMismatches(at url: URL, commit: String) throws -> [String] {
        let git = Git(repo: url)
        let listing = try git.run(["ls-tree", "-r", "-z", commit])
        var mismatches: [String] = []
        for record in listing.split(separator: "\0", omittingEmptySubsequences: true) {
            // "<mode> SP <type> SP <sha>\t<path>"
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[record.startIndex..<tab].split(separator: " ")
            guard meta.count >= 3 else { continue }
            let mode = String(meta[0]), blob = String(meta[2])
            let path = String(record[record.index(after: tab)...])
            guard mode != "160000" else { continue }

            let file = url.appendingPathComponent(path)
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                mismatches.append("\(path) (missing)")
                continue
            }
            let bytes: Data
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: file.path) else {
                    mismatches.append("\(path) (unreadable symbolic link)")
                    continue
                }
                bytes = Data(target.utf8)
            } else {
                guard let data = try? Data(contentsOf: file) else {
                    mismatches.append("\(path) (unreadable)")
                    continue
                }
                bytes = data
            }
            if blobIdentifier(bytes) != blob {
                mismatches.append("\(path) (content does not match the commit's blob \(blob))")
            }
        }
        return mismatches
    }

    /// git's blob object id for `bytes`: SHA-1 over `"blob <length>\0"` then the
    /// content. Computed here rather than shelled out to `git hash-object` so
    /// the comparison depends on no git configuration at all -- `hash-object`
    /// without `--no-filters` would run the very filter this is checking for.
    ///
    /// SHA-1 is git's object format, so this is interoperability, not a
    /// security choice: the value it is compared against is a git blob id.
    /// Forging a collision here would also have to produce a valid blob whose
    /// id matches one recorded in a commit the baseline record pins by SHA.
    static func blobIdentifier(_ bytes: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(bytes.count)\u{0}".utf8))
        hasher.update(data: bytes)
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

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

        // ---- POST-CONDITIONS, SAMPLED AFTER THE LAST THING THAT COULD CHANGE
        // THEM, which is the checkout itself. ----
        //
        // The previous version sampled `indexFlaggedPaths` only BEFORE the
        // checkout, and that is precisely how a `post-checkout` hook beat it:
        // the hook re-set `--skip-worktree` and re-tampered AFTER the restore,
        // so `flagged` was empty, `git status` was lied to by the fresh flag,
        // and the eval returned `rc 0, keep, ratio 0.10045` with NO WARNING AT
        // ALL. Hooks are denied now (`Git.hookDenial`), but a post-condition
        // that can only be true if some other defence held is not a
        // post-condition. Re-sampled here, and the two are unioned so the
        // warning names everything that was flagged at any point.
        let afterCheckout = (try? indexFlaggedPaths(at: url)) ?? []
        var reported = flagged
        if !afterCheckout.isEmpty {
            // ONE repair round, deliberately bounded. Something set these
            // during the checkout; clear them and restore once more, then
            // insist. An unbounded loop against an adversary that re-flags on
            // every checkout would spin forever instead of refusing.
            let worktreeGit = Git(repo: url)
            for flag in ["--no-assume-unchanged", "--no-skip-worktree"] {
                _ = try? worktreeGit.run(
                    ["update-index", flag, "--"] + afterCheckout.map(\.path))
            }
            try repoint(git: git, at: url, to: commit)
            let residual = (try? indexFlaggedPaths(at: url)) ?? []
            guard residual.isEmpty else {
                throw GitError.command(
                    "update-index --no-assume-unchanged/--no-skip-worktree", 0, """
                    \(residual.count) path(s) are marked assume-unchanged or skip-worktree again \
                    after being cleared and re-restored: \
                    \(residual.map { "\($0.tag) \($0.path)" }.prefix(20).joined(separator: ", ")). \
                    Something is re-flagging them during the checkout itself.
                    """)
            }
            reported += afterCheckout
        }

        // CONTENT, not `git status`. `verify` is kept for the cheap HEAD-and-
        // cleanliness signal, but it cannot be the last word: a
        // `.gitattributes` smudge filter rewrites a file DURING this checkout
        // and the matching clean filter makes `git status` report it as
        // unmodified -- measured, worktree `17500` against a commit holding
        // `1750`, status empty. `contentMismatches` hashes the bytes on disk
        // against the blob ids in the commit and asks git nothing.
        guard try verify(at: url, expectedCommit: commit) else {
            throw GitError.command(
                "checkout --detach --force \(commit)", 0,
                "the worktree is still not a clean checkout of \(commit) after being restored")
        }
        let mismatches = try contentMismatches(at: url, commit: commit)
        guard mismatches.isEmpty else {
            throw GitError.command(
                "checkout --detach --force \(commit)", 0, """
                \(mismatches.count) file(s) in the worktree do not match the bytes recorded at \
                \(commit), even though git reports the tree as clean: \
                \(mismatches.prefix(20).joined(separator: "; ")). A .gitattributes filter driver \
                rewrites files during checkout and makes git compare the rewritten copy back as \
                though it were unchanged.
                """)
        }
        return reported
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
