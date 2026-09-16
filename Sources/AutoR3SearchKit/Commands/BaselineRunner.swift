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
    /// symlinked frozen directory, for the same reason.
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

    /// Which directories to freeze, and a warning to surface instead of a
    /// hard failure when `swift package describe` could not even run.
    ///
    /// DECISION: a manifest that fails to describe at all is treated the
    /// same permissive way a warm build failure is (see `warmBuild` below) --
    /// both are "this repository cannot currently be built/measured" rather
    /// than "an agent tampered with a frozen file", and `baseline` exists to
    /// help establish measurement infrastructure, not to additionally
    /// gatekeep manifest health that `swift build`/`swift test` will refuse
    /// on their own merits at `eval` time regardless. What `describe` DOES
    /// manage to report, though, is held to the hard standard `run` enforces
    /// below (`missingFrozenDirectory`, `emptyFreezeManifest`): a real
    /// description with zero test/benchmark targets is refused, because that
    /// is exactly the silent-nothing-protected failure those checks exist
    /// to catch, and by the time `baseline` runs, `init` has already
    /// required at least one benchmark target to exist.
    private static func frozenDirectories(repo: URL) -> (directories: [String], warning: String?) {
        do {
            let description = try PackageDescribe.describe(repo: repo)
            return (description.frozenDirectories, nil)
        } catch {
            return ([], """
                could not determine which directories to freeze: swift package describe failed \
                (\(error)). No test/benchmark protection was established for this baseline -- \
                fix the package manifest (the same one swift build needs) and establish a fresh \
                baseline before relying on this run's KEEP/DISCARD verdicts.
                """)
        }
    }

    /// Runs `swift build -c release --product <name>` in the pinned
    /// worktree for the benchmark target (when known) and for
    /// `BenchmarkTool` itself, so the first `eval` reuses a warm `.build`
    /// instead of paying a cold Swift build. Best-effort: see
    /// `frozenDirectories` for why a build that cannot succeed does not
    /// block `baseline` from completing.
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

    /// Keeps the pinned worktree's warmed `.build` alive across every KEEP.
    ///
    /// `Worktree.repoint` runs `git clean -fd` after every advance, which
    /// deletes untracked-but-not-ignored files. `.build` is untracked
    /// (SwiftPM output), so it must be ignored somewhere `clean -fd` reads --
    /// but never via the MEASURED repository's tracked `.gitignore`: a
    /// tracked-file edit would show up as a change since `frozenCommit` and
    /// could trip Task 17's scope gate, and it would be visible to (and
    /// revertible by) the very agent this pin exists to be safe from.
    /// `.git/info/exclude` is untracked, local to this git checkout's
    /// administrative files, and invisible to an agent editing the
    /// repository's tracked content -- exactly what a machine-local "don't
    /// clean this" note should be.
    ///
    /// Resolved via `rev-parse --git-common-dir` run FROM the worktree,
    /// rather than assuming `<repo>/.git/info/exclude`, so this keeps
    /// working if `repo` itself is ever something other than a plain
    /// checkout. In practice (verified empirically against git 2.54 while
    /// implementing this) `info/exclude` is one of the files a linked
    /// worktree shares with the common git directory -- there is no
    /// separate per-worktree `info/exclude` that git actually reads -- so
    /// this also quietly protects a `.build` the operator builds in their
    /// own checkout of the same repository. That's a harmless, arguably
    /// beneficial side effect, and it is still not the tracked `.gitignore`.
    private static func ensureWorktreeIgnoresBuildOutput(git: Git, worktreeURL: URL) throws {
        let commonDir = try git.run(["rev-parse", "--git-common-dir"], cwd: worktreeURL)
        let excludeURL = URL(fileURLWithPath: commonDir, isDirectory: true, relativeTo: worktreeURL)
            .standardizedFileURL
            .appendingPathComponent("info/exclude")
        try FileManager.default.createDirectory(
            at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let marker = "# autor3search-swift: warmed .build cache in the pinned baseline worktree"
        let block = "\(marker)\n.build/\n"
        guard FileManager.default.fileExists(atPath: excludeURL.path) else {
            try block.write(to: excludeURL, atomically: true, encoding: .utf8)
            return
        }
        let existing = try String(contentsOf: excludeURL, encoding: .utf8)
        guard !existing.contains(marker) else { return }
        let needsNewline = !existing.isEmpty && !existing.hasSuffix("\n")
        try (existing + (needsNewline ? "\n" : "") + block)
            .write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    /// Freezes the success criteria and pins the measurement point.
    ///
    /// ORDERING (see the written report for the full reasoning): the dirty-
    /// tree check and the tag-reuse check happen before any side effect, so
    /// a refusal from either leaves nothing behind to clean up. Everything
    /// after that -- branch, frozen snapshot, worktree, warm build -- is
    /// either idempotent (the branch and worktree steps check what already
    /// exists before creating it) or explicitly non-fatal (the warm build
    /// and a `swift package describe` failure only warn), so a `baseline`
    /// interrupted partway through (a killed process, a transient git
    /// failure) can always be retried with the SAME tag: reuse is gated on
    /// `baseline.json` existing, and that file is written last, atomically,
    /// only once every step before it has actually succeeded.
    @discardableResult
    public static func run(repo: URL, tag: String, env: [String: String]) throws -> BaselineRecord {
        let git = Git(repo: repo)
        guard try git.isClean() else { throw BaselineError.dirtyTree }

        let home = try StateHome(repo: repo, env: env)
        let recordURL = try home.baselineRecordURL(tag: tag)
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw BaselineError.tagInUse(tag)
        }

        let branch = "autor3search-swift/\(tag)"
        if git.branchExists(branch) {
            try git.run(["checkout", "-q", branch])
        } else {
            try git.createBranch(branch)
        }
        let commit = try git.head()

        // Freeze tests AND benchmarks exactly once, here -- never again for
        // this run. A later re-snapshot would let an agent that renamed a
        // test directory slip out of the freeze silently.
        let (dirs, describeWarning) = frozenDirectories(repo: repo)
        if let describeWarning { warn(describeWarning) }
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
        if describeWarning == nil {
            // Only when the package genuinely described successfully: an
            // empty manifest here means the package really has no
            // test/benchmark targets (or every one of them is empty), the
            // pathological case this hard-fail exists to catch. When
            // describe itself could not run, `dirs` is `[]` by
            // construction and this check would always trip -- that path
            // already warned above and is handled the same permissive way
            // a failing warm build is.
            guard !snapshot.manifest.isEmpty else { throw BaselineError.emptyFreezeManifest }
        }
        try snapshot.save(to: frozenStore.appendingPathComponent("manifest.json"))

        let worktreeURL = try home.worktreeURL(tag: tag)
        if (try? Worktree.verify(at: worktreeURL, expectedCommit: commit)) != true {
            try Worktree.add(git: git, at: worktreeURL, commit: commit)
        }
        try ensureWorktreeIgnoresBuildOutput(git: git, worktreeURL: worktreeURL)

        // Warm the release build so every eval after this one reuses it
        // instead of paying a cold Swift build. Best-effort: see
        // `frozenDirectories` above for why a repository that cannot
        // currently build does not block baseline from completing.
        let config = try? Config.load(repo.appendingPathComponent(".autor3search/config.yaml"))
        for message in warmBuild(worktree: worktreeURL, benchmarkTarget: config?.benchmarkTarget) {
            warn(message)
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
