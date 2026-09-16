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

    /// A file that must be hashed is not there. Previously `sha256File`
    /// answered "the hash of zero bytes" for this, which is how "this
    /// repository has no `Package.resolved`" became indistinguishable from
    /// "this repository's `Package.resolved` is empty" -- a well-formed
    /// 64-hex pin that pins nothing at all, recorded without a word of
    /// complaint. Missing and empty are different states and this makes them
    /// different outcomes.
    case missingFileForHash(String)

    /// The package has an external dependency set SwiftPM pins in
    /// `Package.resolved`, and there is no `Package.resolved` to pin it.
    ///
    /// Refused rather than recorded as "absent", because an unpinned
    /// dependency set defeats the purpose of gate 2 -- the agent could win by
    /// changing a dependency -- and because the first `eval`'s own build
    /// CREATES the file, after which every experiment is permanently
    /// `manifest_change_rejected` (if the agent commits it) or
    /// `dirty_working_tree` (if it does not), with no way out, since
    /// `frozenCommit` never advances.
    case unpinnedDependencies(identities: [String])

    /// A `Package.resolved` is on disk but git is not tracking it -- almost
    /// always because it is named in `.gitignore`, which is what `doctor`
    /// itself used to recommend. An ignored lockfile is not pinned by
    /// anything: it is absent from `frozenCommit`, so every later worktree
    /// checkout resolves its own, and the hash recorded here describes a file
    /// no subsequent run is guaranteed to see.
    case lockfileNotTracked

    /// Whether this package needs a lockfile could not be established --
    /// `swift package resolve` failed to run or exited non-zero (no network,
    /// a private dependency without credentials, an unreachable URL). Failing
    /// closed, because the alternative is to record "no dependencies to pin"
    /// on the strength of a check that never ran, which is the exact class of
    /// silent-success failure this project has been bitten by repeatedly.
    case dependencyPinUndetermined(String)

    /// The manifest inventory could not be built. Fatal for the same reason
    /// `packageDescribeFailed` is: a baseline that records an EMPTY inventory
    /// because the scan could not run protects nothing, and reports success.
    case manifestInventoryFailed(String)

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
        case .missingFileForHash(let path):
            return """
            refusing to establish a baseline: \(path) does not exist, so there is nothing to \
            hash. Recording the hash of zero bytes here would look exactly like a real pin while \
            pinning nothing -- "missing" and "empty" must not be the same 64 hex characters.
            """
        case .unpinnedDependencies(let identities):
            let named = identities.isEmpty
                ? ""
                : " (declared dependencies: \(identities.joined(separator: ", ")))"
            return """
            refusing to establish a baseline: this package resolves external dependencies\(named) \
            but has no \(Lockfile.name). baseline pins that file's hash so the dependency set \
            cannot move mid-run -- gate 2 exists precisely so the agent cannot win by changing a \
            dependency -- and with no lockfile there is nothing to pin.

            This is not a cosmetic refusal. `swift package describe` does not write \
            \(Lockfile.name), but `swift build` does, into the package root -- so the FIRST eval \
            would create it, and from then on every experiment would fail permanently: \
            manifest_change_rejected if the agent commits it, dirty_working_tree if it does not. \
            frozenCommit never advances, so neither door reopens.

            Fix: run `autor3search-swift init` (which now runs `swift package resolve` and \
            commits the result), or by hand:

              swift package resolve && git add \(Lockfile.name) && git commit -m "pin dependencies"

            Do NOT add \(Lockfile.name) to .gitignore. That silences the symptom and leaves every \
            dependency unpinned forever.
            """
        case .lockfileNotTracked:
            return """
            refusing to establish a baseline: \(Lockfile.name) exists on disk but git is not \
            tracking it -- check whether .gitignore names it. An ignored lockfile is pinned by \
            nothing: it is absent from frozenCommit, so every later worktree checkout resolves \
            its own, and the hash recorded here would describe a file no subsequent run is \
            guaranteed to see.

            Fix: remove \(Lockfile.name) from .gitignore, then \
            `git add \(Lockfile.name) && git commit -m "pin dependencies"`.
            """
        case .dependencyPinUndetermined(let why):
            return """
            refusing to establish a baseline: could not determine whether this package needs a \
            \(Lockfile.name), because `swift package resolve` did not succeed (\(why)).

            Treating that as "no dependencies to pin" would record a baseline on the strength of \
            a check that never ran. Fix whatever stopped the resolve -- network, credentials for \
            a private dependency, an unreachable dependency URL, a broken manifest -- and retry.
            """
        case .manifestInventoryFailed(let why):
            return """
            refusing to establish a baseline: could not inventory this repository's manifests \
            (\(why)).

            baseline records the hash of every Package.swift, Package.resolved, version-specific \
            manifest and .swiftpm file in the tree, and eval compares the bytes on disk against \
            it -- that is what stops a nested manifest being rewritten behind git's back. \
            Recording an empty inventory because the scan could not run would protect nothing and \
            still report success.
            """
        }
    }
}

public enum BaselineRunner {
    /// SHA-256 of a file's exact bytes, lowercase hex.
    ///
    /// A MISSING FILE THROWS. It used to hash as empty data, on the theory
    /// that "this file doesn't exist" is itself part of what gets pinned --
    /// and that theory is exactly how this project shipped a defect that
    /// bricked every repository with external dependencies. The hash of zero
    /// bytes (`e3b0c442...`) is a perfectly well-formed SHA-256; written into
    /// `baseline.json` it is indistinguishable from a real pin, so a
    /// repository with source-control dependencies and no lockfile recorded
    /// "no dependencies at all" and reported success. Missing and empty are
    /// different states; they now have different outcomes, and the caller
    /// decides what a missing file means rather than being handed a
    /// plausible-looking wrong answer.
    ///
    /// The one caller that legitimately has to cope with absence is the
    /// lockfile pin (see `resolveLockfilePin`), which records
    /// `Lockfile.absentPin` -- a value no hash can ever equal -- and only
    /// after SwiftPM itself has confirmed the package produces no lockfile.
    static func sha256File(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BaselineError.missingFileForHash(url.path)
        }
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// EVERY manifest-or-manifest-equivalent file under `repo`, as a relative
    /// path -> SHA-256 map. `baseline` records this; gate 2a compares against
    /// it. See `BaselineRecord.manifestSHA256` for why it exists.
    ///
    /// "Manifest" is `ScopeGate.isManifestPath` and nothing else. Reusing that
    /// one predicate is the point: an inventory built from its own private
    /// idea of what a manifest is would drift from the scope gate the first
    /// time either changed, and the gap between the two would be a bypass
    /// nobody was looking at.
    ///
    /// SCANNED FROM DISK, not from `git ls-tree`. This is what makes the
    /// APPEARANCE check work without false positives. A manifest-equivalent
    /// file that is present but GITIGNORED -- an Xcode-written `.swiftpm/`,
    /// say -- is invisible to git, so a git-derived inventory would not record
    /// it and the first `eval` would report it as newly appeared on a
    /// repository where nothing had changed. Disk sees exactly what `swift
    /// build` sees, which is the surface that actually matters. `baseline` has
    /// already verified the tree is clean by the time this runs, so disk and
    /// `frozenCommit` agree on everything git can see.
    ///
    /// `.git` and `.build` are skipped. `.build` is not optional politeness:
    /// it holds every dependency's checkout, each with its own
    /// `Package.swift`, so scanning it would inventory hundreds of files that
    /// SwiftPM rewrites at will and turn every eval into a rejection.
    static func manifestInventory(repo: URL) throws -> [String: String] {
        let root = repo.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else {
            throw BaselineError.manifestInventoryFailed("could not enumerate \(root.path)")
        }

        var inventory: [String: String] = [:]
        for case let item as URL in walker {
            let name = item.lastPathComponent
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, name == ".git" || name == ".build" {
                walker.skipDescendants()
                continue
            }
            guard !isDirectory else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(root.path + "/") else { continue }
            let relative = String(full.dropFirst(root.path.count + 1))
            guard ScopeGate.isManifestPath(relative) else { continue }
            inventory[relative] = try sha256File(item)
        }
        return inventory
    }

    /// What goes into `BaselineRecord.packageResolvedSHA256`: either the
    /// lockfile's real hash, or `Lockfile.absentPin` -- never the hash of
    /// nothing, and never a pin established without checking.
    ///
    /// Four states, three of them refusals:
    ///
    /// 1. A lockfile exists and git tracks it -> pin its real bytes. (The
    ///    dirty-tree guard at the top of `run` already guarantees a tracked
    ///    file on disk matches what is committed at `frozenCommit`.)
    /// 2. A lockfile exists and git does NOT track it -> `lockfileNotTracked`.
    ///    A clean tree plus an untracked file means an ignore rule is hiding
    ///    it; see that case's own reasoning.
    /// 3. No lockfile, and SwiftPM produces none -> `Lockfile.absentPin`. THE
    ///    EDGE CASE THAT MUST KEEP WORKING: a package with no external
    ///    dependencies legitimately has no lockfile and never will, and
    ///    refusing here would be a worse bug than the one this fixes.
    /// 4. No lockfile, but SwiftPM produces one -> `unpinnedDependencies`.
    ///
    /// The 3-vs-4 split is decided by ASKING SWIFTPM, not by reading the
    /// manifest. `swift package describe`'s top-level `dependencies` array
    /// reports only DIRECT dependencies, and a `fileSystem` (path) dependency
    /// whose own manifest declares a `sourceControl` one makes the root
    /// package produce a `Package.resolved` while describe shows nothing but
    /// `fileSystem` -- verified live, and the reason a manifest-only test
    /// would silently under-report. `Lockfile.probe` runs `swift package
    /// resolve` and reads what appears on disk, which cannot be fooled that
    /// way.
    ///
    /// The probe runs in the PINNED WORKTREE, never in `repo`: it writes
    /// `Package.resolved` and `.build/`, and `repo`'s cleanliness is what
    /// every later gate depends on. The worktree is disposable and is reset
    /// to `frozenCommit` at the end of `run` anyway.
    private static func resolveLockfilePin(repo: URL, worktree: URL) throws -> String {
        if Lockfile.exists(in: repo) {
            guard Lockfile.isTracked(repo: repo) != false else {
                throw BaselineError.lockfileNotTracked
            }
            return try sha256File(Lockfile.url(in: repo))
        }
        switch Lockfile.probe(in: worktree) {
        case .notProduced:
            return Lockfile.absentPin
        case .required:
            throw BaselineError.unpinnedDependencies(
                identities: (try? Lockfile.externalDependencyIdentities(repo: repo)) ?? [])
        case .undetermined(let why):
            throw BaselineError.dependencyPinUndetermined(why)
        }
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

        // Hashed HERE, before the first side effect, not at the bottom next to
        // the lockfile pin.
        //
        // ROUND 2, raised as LOW 6. `sha256File` now THROWS on a missing file
        // (which is the whole point -- it used to answer "the hash of zero
        // bytes" and that is how the dependency pin came to pin nothing). But
        // in round 1 these two calls still sat at the bottom of `run`, so a
        // repository with no `.autor3search/config.yaml` -- `baseline` run
        // before `init`, the ordinary mistake -- now failed AFTER the run
        // branch had been created, the frozen snapshot written and the
        // worktree pinned, leaving all of it behind for an error that was
        // knowable from the start. Reading them up here restores the ordering
        // guarantee this function's own doc comment claims: every refusal that
        // can happen leaves nothing to clean up.
        //
        // It also closes a TOCTOU window. Recording a hash taken at the end
        // would pin whatever the file became during the warm build; these are
        // the bytes as they were when the tree was verified clean.
        let configSHA256 = try sha256File(repo.appendingPathComponent(".autor3search/config.yaml"))
        let packageSwiftSHA256 = try sha256File(repo.appendingPathComponent("Package.swift"))
        // The manifest inventory belongs here for the same two reasons: a
        // failure leaves nothing behind, and the hashes are the bytes from the
        // moment the tree was verified clean rather than whatever the warm
        // build left lying around.
        let manifestSHA256 = try manifestInventory(repo: repo)

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

        // THE DEPENDENCY PIN, decided before anything expensive happens and
        // before `baseline.json` is written. Runs here rather than alongside
        // the other two hashes at the bottom because it needs the pinned
        // worktree to probe in -- see `resolveLockfilePin`. A refusal at this
        // point leaves only idempotent, retryable side effects behind (the
        // branch, the frozen snapshot, the worktree), exactly like every other
        // refusal after the two pre-side-effect guards.
        let packageResolvedPin = try resolveLockfilePin(repo: repo, worktree: worktreeURL)

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
                    worktree; reset the worktree to frozenCommit to restore the cleanliness \
                    Task 17's worktree-integrity gate depends on. A fresh Package.resolved used \
                    to be the usual cause and no longer can be: a package that produces one now \
                    has to have it tracked before this point (see resolveLockfilePin), so \
                    anything left here is something else worth looking at.
                    """)
            }
        }

        let record = BaselineRecord(
            tag: tag,
            frozenCommit: commit,
            measurementCommit: commit,
            configSHA256: configSHA256,
            packageSwiftSHA256: packageSwiftSHA256,
            packageResolvedSHA256: packageResolvedPin,
            toolVersion: BuildInfo.version,
            manifestSHA256: manifestSHA256)
        try record.save(to: recordURL)
        return record
    }
}
