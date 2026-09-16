import Foundation
import Crypto

/// Refusals raised while freezing or restoring a repository's test and
/// benchmark files.
///
/// Every case here is a refusal, never a repair. Restore runs unattended, in
/// a loop, overnight, against a repository an AI agent is actively editing.
/// The only safe response to a path that does not look exactly the way it
/// looked at baseline is to stop and say so.
public enum FrozenError: Error, CustomStringConvertible, Equatable {
    /// A file inside a frozen directory was a symbolic link when the baseline
    /// was taken.
    case symlinkAtSnapshot(String)

    /// The destination of a restore is now a symbolic link. It was a regular
    /// file at baseline, so something replaced it after the fact. This is the
    /// attack this type exists to stop.
    case symlinkAtRestore(String)

    /// A relative path that is not a plain, repository-contained relative
    /// path: absolute, tilde-rooted, or containing `.`, `..`, or an empty
    /// component.
    case escapingPath(String)

    /// A *directory* component on the way to a frozen file is a symbolic
    /// link. A check on the final component alone does not catch this: the
    /// kernel resolves every component before the last one, so `Tests` being
    /// swapped for a link to somewhere else lands the write outside the
    /// repository while the leaf still looks like an ordinary file.
    case symlinkInPath(String)

    /// The destination of a restore is a regular file with more than one
    /// directory entry pointing at its inode. Writing to it in place would
    /// change the contents seen through every other name for that inode,
    /// including names outside the repository.
    case hardLinkAtRestore(String)

    public var description: String {
        switch self {
        case .symlinkAtSnapshot(let p):
            return "refusing to freeze \(p): it is a symbolic link, not a regular file"
        case .symlinkAtRestore(let p):
            return """
            refusing to restore \(p): it is now a symbolic link. Writing through it would \
            overwrite a file outside the repository.
            """
        case .escapingPath(let p):
            return "refusing path \(p): it escapes the repository after normalization"
        case .symlinkInPath(let p):
            return """
            refusing to use \(p): a directory on the path to a frozen file is a symbolic \
            link. Reading or writing through it would leave the repository.
            """
        case .hardLinkAtRestore(let p):
            return """
            refusing to restore \(p): it is a hard link. Writing to it would also rewrite \
            every other name for the same file, including names outside the repository.
            """
        }
    }
}

/// The contents of a repository's test and benchmark files as they stood at
/// baseline, hashed and copied to a store outside the repository.
///
/// The point of the type is adversarial. An agent asked to make a benchmark
/// faster can always make it faster by making the tests stop checking
/// anything, so the harness puts the baseline copies where the agent cannot
/// reach them and writes them back over the repository before every
/// measurement. `restore` therefore writes attacker-influenced paths to disk
/// on the operator's machine, unattended. Every guard below exists because
/// of that.
public struct FrozenSnapshot: Sendable, Codable, Equatable {
    /// Repository-relative path -> SHA-256 of that file's contents at
    /// baseline, lowercase hex.
    public let manifest: [String: String]

    public init(manifest: [String: String]) {
        self.manifest = manifest
    }

    // MARK: - Path hygiene

    /// Validates that `rel` is a plain relative path contained by the
    /// repository and returns it with trailing slashes trimmed.
    ///
    /// This is component-wise on purpose. The obvious implementation —
    /// normalise with `NSString.standardizingPath` and look for a leading
    /// `..` — is leaky: it leaves `Tests/..` alone (it cannot know whether
    /// `Tests` is a link, so it must not collapse it) and it *expands* a
    /// leading `~` into an absolute home-directory path, turning a check
    /// into a path rewrite. Rejecting each component outright has no such
    /// corners.
    @discardableResult
    static func checked(relative rel: String) throws -> String {
        var trimmed = rel
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw FrozenError.escapingPath(rel)
        }
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw FrozenError.escapingPath(rel)
            }
        }
        return trimmed
    }

    /// `lstat`, not `stat`: attributes of the link itself when the final
    /// component is a link.
    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    static func isSymlink(_ url: URL) -> Bool {
        (attributes(url)?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Number of directory entries pointing at this inode. Absent or
    /// unreadable is reported as 1 so a missing file is never mistaken for a
    /// hard link; the caller has already established what it is looking at.
    private static func linkCount(_ url: URL) -> Int {
        (attributes(url)?[.referenceCount] as? Int) ?? 1
    }

    /// Refuses if any component of `rel` *before the last one* is a symbolic
    /// link. `isSymlink` on the leaf is not sufficient, because the kernel
    /// resolves the parent components first; a link at `Tests` makes
    /// `Tests/DemoTests/T.swift` an ordinary file at an address that is no
    /// longer inside the repository.
    ///
    /// Components that do not exist yet are not links, and are left for
    /// `createDirectory` to make as real directories.
    static func checkAncestors(repo: URL, relative rel: String) throws {
        let components = rel.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var url = repo
        var prefix = ""
        for component in components.dropLast() {
            url.appendPathComponent(component)
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            guard !isSymlink(url) else { throw FrozenError.symlinkInPath(prefix) }
        }
    }

    /// Path of `url` relative to `repo`, refusing anything that is not
    /// actually underneath `repo`.
    private static func relativePath(of url: URL, to repo: URL) throws -> String {
        let repoPath = repo.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        guard filePath.hasPrefix(prefix), filePath.count > prefix.count else {
            throw FrozenError.escapingPath(filePath)
        }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Enumeration

    /// Every regular file, and every symbolic link, under `directories`, as
    /// repository-relative paths, sorted.
    ///
    /// Links are *included* rather than skipped so that callers see them:
    /// `snapshot` refuses them outright, and `newFiles` reports one planted
    /// after baseline as a new file rather than letting it pass unmentioned.
    private static func files(in repo: URL, directories: [String]) throws -> [String] {
        var out: [String] = []
        for directory in directories {
            let dir = try checked(relative: directory)
            try checkAncestors(repo: repo, relative: dir)
            let base = repo.appendingPathComponent(dir)

            // A frozen directory that is itself a link must never be walked.
            // Foundation's enumerator yields nothing at all for a symlinked
            // base, so without this the freeze would silently cover no files
            // — the worst possible failure for a protection mechanism.
            guard !isSymlink(base) else { throw FrozenError.symlinkInPath(dir) }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir),
                  isDir.boolValue,
                  let enumerator = FileManager.default.enumerator(
                    at: base, includingPropertiesForKeys: nil)
            else { continue }

            for case let url as URL in enumerator {
                let rel = try relativePath(of: url, to: repo)
                // lstat semantics: decide before following anything. The
                // enumerator does not descend into symlinked directories, so
                // a link is always surfaced here as a single entry.
                if isSymlink(url) { out.append(rel); continue }
                var itemIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &itemIsDir),
                      !itemIsDir.boolValue
                else { continue }
                out.append(rel)
            }
        }
        // `directories` may overlap (`Tests` and `Tests/DemoTests`), which
        // would otherwise report the same file twice to `newFiles`.
        return Array(Set(out)).sorted()
    }

    // MARK: - Snapshot

    /// Copies every file under `directories` into `store` and records its
    /// SHA-256. Refuses if any of them is a symbolic link, or if any
    /// directory on the way to one is.
    public static func snapshot(
        repo: URL, directories: [String], into store: URL
    ) throws -> FrozenSnapshot {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for path in try files(in: repo, directories: directories) {
            let rel = try checked(relative: path)
            try checkAncestors(repo: repo, relative: rel)
            let src = repo.appendingPathComponent(rel)
            guard !isSymlink(src) else { throw FrozenError.symlinkAtSnapshot(rel) }
            let data = try Data(contentsOf: src)
            manifest[rel] = sha256(data)
            let dst = store.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dst, options: .atomic)
        }
        return FrozenSnapshot(manifest: manifest)
    }

    // MARK: - Restore

    /// Writes every frozen file back over the repository, erasing whatever
    /// the agent did to it.
    ///
    /// The write is deliberately an ordinary in-place write, and the refusals
    /// below are deliberately explicit rather than folded into the write
    /// call. An in-place write follows a symbolic link at the destination, so
    /// the guards here are the entire security boundary and deleting one is
    /// immediately visible as an arbitrary-file-overwrite in the test suite.
    /// A boundary that is enforced twice, once explicitly and once as a side
    /// effect of a library call's implementation, is a boundary nobody can
    /// tell is still working.
    ///
    /// A refusal aborts the whole restore, which can leave earlier files
    /// already written back. That is intended: the caller treats a restore
    /// failure as a hard abort of the run, and restore is idempotent, so the
    /// next attempt after the operator has investigated starts clean.
    public func restore(repo: URL, from store: URL) throws {
        for path in manifest.keys.sorted() {
            let rel = try FrozenSnapshot.checked(relative: path)
            let data = try Data(contentsOf: store.appendingPathComponent(rel))
            let dst = repo.appendingPathComponent(rel)

            // Before creating anything: `createDirectory` happily follows a
            // symlinked ancestor and would materialise the run's directory
            // tree outside the repository.
            try FrozenSnapshot.checkAncestors(repo: repo, relative: rel)
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Check BEFORE writing. A link planted after baseline must fail loudly.
            guard !FrozenSnapshot.isSymlink(dst) else { throw FrozenError.symlinkAtRestore(rel) }
            guard FrozenSnapshot.linkCount(dst) <= 1 else {
                throw FrozenError.hardLinkAtRestore(rel)
            }
            try data.write(to: dst)
        }
    }

    // MARK: - New files

    /// Files present under `directories` now that were not in the manifest at
    /// baseline. SwiftPM compiles a new file in an existing test target with
    /// no `Package.swift` edit, so an unnoticed new file is a way to add a
    /// passing test that shadows a frozen failing one.
    public func newFiles(repo: URL, directories: [String]) throws -> [String] {
        try FrozenSnapshot.files(in: repo, directories: directories)
            .filter { manifest[$0] == nil }
    }

    // MARK: - Persistence

    /// Writes the manifest as JSON.
    ///
    /// The manifest has to outlive the process that made it. `baseline` and
    /// `eval` are separate invocations, and the question `eval` asks — "is
    /// this file new since baseline?" — can only be answered against what
    /// baseline actually recorded. Re-deriving the manifest by hashing the
    /// store would answer a different question ("what is in the store now?")
    /// that happens to give the same answer while nothing has gone wrong.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads a manifest written by `save`, re-validating every path in it.
    /// The file lives outside the repository, but it is the direct source of
    /// the paths `restore` writes to, so it is checked on the way in as well
    /// as on the way out.
    public static func load(_ url: URL) throws -> FrozenSnapshot {
        let snapshot = try JSONDecoder().decode(FrozenSnapshot.self, from: Data(contentsOf: url))
        for path in snapshot.manifest.keys { try checked(relative: path) }
        return snapshot
    }
}
