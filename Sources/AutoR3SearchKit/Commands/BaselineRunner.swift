// Sources/AutoR3SearchKit/Commands/BaselineRunner.swift
//
// `baseline` freezes the success criteria and pins the measurement point. It
// records two commits that must never be conflated (see `BaselineRecord`):
// `frozenCommit` (what the frozen files and the scope gate always compare
// against; never advances) and `measurementCommit` (what timings are
// measured against; advances on every KEEP, starting equal to
// `frozenCommit`). This file only ever writes them equal -- Task 17 owns the
// advance.
import Foundation
import Crypto

public enum BaselineError: Error, CustomStringConvertible, Equatable {
    /// The repository under test has uncommitted changes.
    case dirtyTree

    /// `tag` already has a completed baseline.
    case tagInUse(String)

    /// The run branch `autor3search-swift/<tag>` already exists, but not at
    /// the repository's current HEAD. This happens when an earlier attempt
    /// at this tag created the branch but never finished (no `baseline.json`
    /// was written -- see `tagInUse`) and the repository has since moved on.
    /// Checking out the stale branch tip and freezing THAT commit, instead
    /// of the operator's current HEAD, would silently pin the wrong commit
    /// and still report success.
    case staleRunBranch(tag: String, branchCommit: String, headCommit: String)

    /// `swift package describe` did not succeed. Fatal, not a warning: this
    /// is the one call that tells `baseline` which directories to freeze,
    /// and it fails for reasons that have nothing to do with an agent
    /// tampering with a frozen file -- transient network loss (it must
    /// resolve dependencies), a renamed or unreachable dependency, expired
    /// credentials for a private one, a toolchain mismatch, or an agent
    /// that broke `Package.swift` between `init` and `baseline`. Continuing
    /// past this with an empty directory list would freeze nothing and
    /// still report success on exactly the run where establishing real
    /// protection matters most.
    case packageDescribeFailed(String)

    /// A directory `swift package describe` reported as a test or benchmark
    /// target does not exist on disk. `FrozenSnapshot` silently skips a
    /// missing directory (it just enumerates nothing there), so without this
    /// check an operator typo -- or a target whose path moved -- would
    /// freeze less than intended and `baseline` would report success anyway.
    /// "Missing" is categorically different from "exists and is empty",
    /// which is fine and not refused here.
    case missingFrozenDirectory(String)

    /// Freezing the package's described test and benchmark directories
    /// produced zero protected files. Weaker than `missingFrozenDirectory`:
    /// even when every named directory genuinely exists, zero frozen files
    /// means nothing is protected and every later KEEP/DISCARD verdict is
    /// meaningless -- the same outcome Task 6 already refuses for a
    /// symlinked frozen directory, for the same reason. Unconditional: this
    /// check runs on every successful `describe`, with no exemption for any
    /// other path.
    case emptyFreezeManifest

    public var description: String {
        switch self {
        case .dirtyTree:
            return """
            working tree is dirty. baseline pins frozenCommit to a specific git SHA -- an \
            uncommitted edit is not reachable from any SHA, so a baseline taken against what \
            is on disk rather than what is in git would not be reproducible. Commit or stash \
            first.
            """
        case .tagInUse(let t):
            return "tag \(t) already has a baseline; choose another"
        case .staleRunBranch(let tag, let branchCommit, let headCommit):
            return """
            refusing to establish baseline \(tag): the run branch autor3search-swift/\(tag) \
            already exists at \(branchCommit), which is not the current HEAD (\(headCommit)). \
            An earlier attempt at this tag likely created the branch and did not finish. \
            Reusing the stale branch tip would silently pin the wrong commit and still report \
            success. Delete or reset the branch, or choose a different tag, and retry.
            """
        case .packageDescribeFailed(let message):
            return """
            refusing to establish a baseline: swift package describe failed (\(message)). \
            Continuing with no directories to freeze would report success while protecting \
            nothing -- exactly the failure this check exists to prevent. Fix the package \
            manifest (the same one swift build needs) and retry.
            """
        case .missingFrozenDirectory(let path):
            return """
            refusing to establish a baseline: \(path) was reported as a test or benchmark \
            target directory but does not exist on disk. Freezing would silently protect less \
            than intended and still report success. Check for a typo in the package manifest, \
            or a target whose path moved.
            """
        case .emptyFreezeManifest:
            return """
            refusing to establish a baseline: freezing the package's test and benchmark \
            directories produced zero protected files. Zero frozen files means nothing is \
            protected, and every later KEEP/DISCARD verdict would be meaningless. Either the \
            package has no test or benchmark targets (add one and re-run init), or every \
            frozen directory is empty.
            """
        }
    }
}

public enum BaselineRunner {
    /// SHA-256 of a file's exact bytes, lowercase hex. A missing file (e.g. a
    /// package with no `Package.resolved` because it has no dependencies)
    /// hashes as empty data rather than throwing -- `BaselineRecord` always
    /// carries all three hash fields, and "this file doesn't exist" is itself
    /// part of what gets pinned, not a reason to fail the whole baseline.
    static func sha256File(_ url: URL) throws -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    /// Runs `swift build -c release --product <name>` in the pinned
    /// worktree for the benchmark target (when known) and for
    /// `BenchmarkTool` itself, so the first `eval` reuses a warm `.build`
    /// instead of paying a cold Swift build. Best-effort: a build that
    /// cannot succeed does not block `baseline` from completing -- `eval`'s
    /// own build gate (Task 17) is where a repository that cannot build
    /// becomes a real, scored refusal, on its own merits, regardless of
    /// what `baseline` decides here.
    private static func warmBuild(worktree: URL, benchmarkTarget: String?) -> [String] {
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        var products = ["BenchmarkTool"]
        if let benchmarkTarget { products.insert(benchmarkTarget, at: 0) }

        var warnings: [String] = []
        for product in products {
            do {
                let result = try Subprocess.run(
                    swift, ["build", "-c", "release", "--product", product],
                    cwd: worktree, env: nil, timeout: 1800)
                guard result.exitCode == 0 else {
                    warnings.append("""
                        warm build of product \(product) failed (exit \(result.exitCode)); the \
                        first eval will pay a cold Swift build instead of reusing a warm cache. \
                        \(result.stderr.suffix(2000))
                        """)
                    continue
                }
            } catch {
                warnings.append("warm build of product \(product) could not run: \(error)")
            }
        }
        return warnings
    }

    /// Whether `url` is a registered git worktree checkout -- `git worktree
    /// add` marks one by writing a `.git` FILE there (not a directory)
    /// containing `gitdir: <path>`. Used to decide, when the pinned
    /// worktree path is not currently verified, whether it is safe to
    /// `repoint` (a registered worktree, just stale or dirty) or whether it
    /// must be cleared and re-added from scratch (nothing registered there
    /// at all, or a corrupt leftover).
    private static func isRegisteredWorktree(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Gets the pinned worktree to exactly `commit`, clean, reusing an
    /// existing registration wherever possible instead of insisting on a
    /// fresh `git worktree add`.
    ///
    /// `git worktree add` refuses outright if the target path already
    /// exists -- so on a retry of an interrupted `baseline` (the worktree
    /// was already added, then a warm build or a later step failed or was
    /// killed), unconditionally calling `add` again would die with `fatal:
    /// '<path>' already exists`, permanently stuck until an operator
    /// manually deletes the run directory. That defeats the "always
    /// retryable with the same tag" property the rest of `run` is designed
    /// around. `Worktree.repoint` (`checkout --force` + `clean -fd`) is the
    /// idempotent way back to a clean checkout at `commit` for anything
    /// already registered; only a stray, unregistered directory needs to be
    /// cleared and re-added.
    private static func pinWorktree(git: Git, at url: URL, to commit: String) throws {
        guard (try? Worktree.verify(at: url, expectedCommit: commit)) != true else { return }
        if isRegisteredWorktree(at: url) {
            try Worktree.repoint(git: git, at: url, to: commit)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? Worktree.remove(git: git, at: url)
            try? FileManager.default.removeItem(at: url)
            try Worktree.add(git: git, at: url, commit: commit)
        } else {
            try Worktree.add(git: git, at: url, commit: commit)
        }
    }

    /// Freezes the success criteria and pins the measurement point.
    ///
    /// ORDERING (see the written report for the full reasoning): the dirty-
    /// tree check and the tag-reuse check happen before any side effect, so
    /// a refusal from either leaves nothing behind to clean up. HEAD is
    /// captured before touching the run branch at all, so an existing but
    /// stale branch (an interrupted earlier attempt, repository since moved
    /// on) is refused rather than silently frozen at the wrong commit.
    /// Everything after that -- branch, frozen snapshot, worktree, warm
    /// build -- is either idempotent (the branch and worktree steps check
    /// what already exists before creating anything) or explicitly
    /// non-fatal (a failing warm build only warns), so a `baseline`
    /// interrupted partway through (a killed process, a transient git
    /// failure) can always be retried with the SAME tag: reuse is gated on
    /// `baseline.json` existing, and that file is written last, atomically,
    /// only once every step before it has actually succeeded. The one hard
    /// failure that is NOT retried-past silently is `swift package
    /// describe` itself failing -- see `BaselineError.packageDescribeFailed`.
    @discardableResult
    public static func run(repo: URL, tag: String, env: [String: String]) throws -> BaselineRecord {
        let git = Git(repo: repo)
        guard try git.isClean() else { throw BaselineError.dirtyTree }

        let home = try StateHome(repo: repo, env: env)
        let recordURL = try home.baselineRecordURL(tag: tag)
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw BaselineError.tagInUse(tag)
        }

        // Captured BEFORE touching the branch: creating or checking out the
        // run branch must never change which commit gets frozen.
        let commit = try git.head()
        let branch = "autor3search-swift/\(tag)"
        if git.branchExists(branch) {
            let branchCommit = try git.run(["rev-parse", branch])
            guard branchCommit == commit else {
                throw BaselineError.staleRunBranch(
                    tag: tag, branchCommit: branchCommit, headCommit: commit)
            }
            try git.run(["checkout", "-q", branch])
        } else {
            try git.createBranch(branch)
        }

        // Freeze tests AND benchmarks exactly once, here -- never again for
        // this run. A later re-snapshot would let an agent that renamed a
        // test directory slip out of the freeze silently.
        //
        // A `swift package describe` that cannot run at all is fatal, not a
        // warning -- see `BaselineError.packageDescribeFailed`. The empty-
        // manifest check below is unconditional for the same reason: there
        // is no path left where an empty freeze set is tolerated silently.
        let description: PackageDescription
        do {
            description = try PackageDescribe.describe(repo: repo)
        } catch {
            throw BaselineError.packageDescribeFailed("\(error)")
        }
        let dirs = description.frozenDirectories
        for dir in dirs {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(dir).path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw BaselineError.missingFrozenDirectory(dir)
            }
        }
        let frozenStore = try home.frozenDir(tag: tag)
        let snapshot = try FrozenSnapshot.snapshot(repo: repo, directories: dirs, into: frozenStore)
        guard !snapshot.manifest.isEmpty else { throw BaselineError.emptyFreezeManifest }
        // R4: the persisted manifest lives at `<run>/frozen-manifest.json`,
        // a sibling of `frozen/` (the file-copy store) and `baseline.json`
        // -- the path Task 17 was told to load.
        try snapshot.save(to: try home.runDir(tag: tag).appendingPathComponent("frozen-manifest.json"))

        // Pin the worktree, reusing an existing registration if one is
        // already there (see `pinWorktree`'s doc comment for why a plain
        // `Worktree.add` is not safe to call unconditionally).
        let worktreeURL = try home.worktreeURL(tag: tag)
        try pinWorktree(git: git, at: worktreeURL, to: commit)

        // Warm the release build so every eval after this one reuses it
        // instead of paying a cold Swift build. Best-effort: see
        // `warmBuild`'s doc comment for why a repository that cannot
        // currently build does not block baseline from completing.
        let config = try? Config.load(repo.appendingPathComponent(".autor3search/config.yaml"))
        for message in warmBuild(worktree: worktreeURL, benchmarkTarget: config?.benchmarkTarget) {
            warn(message)
        }

        // `swift build` can leave the worktree dirty with files SwiftPM
        // writes outside `.build` -- verified empirically: a package with a
        // source-control dependency gets a fresh, untracked
        // `Package.resolved`. `Worktree.verify` folds cleanliness into its
        // verdict (Task 17's worktree-integrity gate is a single `verify`
        // call that must fail closed), so leaving this dirty would make the
        // very first eval after a perfectly healthy baseline refuse.
        // `.build/` itself is already protected: `init` writes it into the
        // repository's TRACKED `.gitignore` before `baseline` can ever run
        // (a dirty tree is refused above), so it is committed at
        // `frozenCommit` and `clean -fd` already leaves it alone. Repoint to
        // the SAME commit -- a no-op checkout whose only job is to run
        // `clean -fd` and reset any tracked-file modification -- to restore
        // that cleanliness before this run's record is written.
        if (try? Worktree.isClean(at: worktreeURL)) != true {
            let buildDirExisted = FileManager.default.fileExists(
                atPath: worktreeURL.appendingPathComponent(".build").path)
            try Worktree.repoint(git: git, at: worktreeURL, to: commit)
            if buildDirExisted,
               !FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent(".build").path) {
                warn("""
                    the warm .build cache was deleted while restoring the pinned worktree to a \
                    clean state, because .gitignore (as committed at frozenCommit) does not \
                    cover .build/. init writes that entry automatically; if this repository's \
                    .gitignore was hand-edited afterward, restore it, or every eval will pay a \
                    cold Swift build.
                    """)
            } else {
                warn("""
                    the warmed release build left untracked or modified files in the pinned \
                    worktree (commonly a fresh Package.resolved for a package with a \
                    source-control dependency); reset the worktree to frozenCommit to restore \
                    the cleanliness Task 17's worktree-integrity gate depends on.
                    """)
            }
        }

        let record = BaselineRecord(
            tag: tag,
            frozenCommit: commit,
            measurementCommit: commit,
            configSHA256: try sha256File(repo.appendingPathComponent(".autor3search/config.yaml")),
            packageSwiftSHA256: try sha256File(repo.appendingPathComponent("Package.swift")),
            packageResolvedSHA256: try sha256File(repo.appendingPathComponent("Package.resolved")),
            toolVersion: BuildInfo.version)
        try record.save(to: recordURL)
        return record
    }
}
