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
    /// directory entry pointing at its inode.
    ///
    /// This is no longer an overwrite-prevention guard: the atomic write
    /// renames a fresh file into place, which detaches the name rather than
    /// rewriting the shared inode, so the other names are safe either way.
    /// It is kept as an integrity signal. A frozen file that has acquired a
    /// second name is not the file that was frozen, and a harness whose whole
    /// job is to detect that the tree stopped matching baseline should say so
    /// rather than quietly paper over it. The check is one `lstat` and has
    /// near-zero false positives: git does not hard-link working-tree files,
    /// neither does `git worktree`, and APFS clones leave the link count at 1.
    case hardLinkAtRestore(String)

    /// A destination exists but could not be inspected. The guards are
    /// fail-closed: not knowing what is about to be written over is a
    /// refusal, never a pass.
    case unreadableDestination(String)

    /// A caller asked to scan a different set of directories from the set the
    /// baseline actually froze.
    ///
    /// Neither `Config` nor `BaselineRecord` carries the frozen-directory
    /// list, so the scan scope at evaluation time is plumbed separately from
    /// the scope that was frozen. Hand the gate a narrower list than baseline
    /// used and the files in the dropped directories are never scanned, never
    /// compared against the manifest, and never reported as new — the gate
    /// silently shrinks and nothing notices. The recorded list is the
    /// authority; disagreeing with it is an error, not a preference.
    case directoriesMismatch(recorded: [String], requested: [String])

    /// The copy of a frozen file IN THE STORE does not hash to what the
    /// manifest recorded for it.
    ///
    /// The store lives outside the repository, which keeps it away from an
    /// agent that only edits the repository -- but it is same-user,
    /// `0755`/`0644`, and the agent has a shell. `restore` used to copy the
    /// store's bytes into the repository without ever comparing them to the
    /// `manifest[rel]` SHA-256 it was already carrying, so one `sed -i` on the
    /// stored benchmark made `eval` INSTALL the attacker's benchmark over the
    /// repository and then measure it: `rc=0, ratio 0.00247`. The manifest is
    /// the record of what was frozen; the store is only a cache of the bytes,
    /// and a cache that disagrees with the record is not to be trusted over it.
    case storeContentMismatch(String, expected: String, actual: String)

    /// A file in the store is a symbolic link. The snapshot refuses to freeze
    /// one, so it cannot have been written by `snapshot`; following it would
    /// read bytes from wherever it points.
    case symlinkInStore(String)

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
            refusing to restore \(p): it is a hard link, so the file in the repository is \
            no longer the file that was frozen. The tree does not match baseline.
            """
        case .unreadableDestination(let p):
            return """
            refusing to restore \(p): it exists but its attributes could not be read, so \
            there is no way to tell what the write would land on.
            """
        case .directoriesMismatch(let recorded, let requested):
            return """
            refusing to scan \(requested.joined(separator: ", ")): the baseline froze \
            \(recorded.joined(separator: ", ")). Scanning a different set would compare \
            the repository against a scope it was never frozen at, and files in any \
            dropped directory would never be reported as new.
            """
        case .storeContentMismatch(let p, let expected, let actual):
            return """
            refusing to restore \(p): the copy in the frozen store does not match the hash the \
            baseline manifest recorded for it (sha256 \(actual), manifest says \(expected)). The \
            store is outside the repository but it is not out of reach -- it is same-user and \
            writable, and the agent has a shell. Writing those bytes back would INSTALL a \
            tampered test or benchmark over the repository and then measure it. Nothing was \
            restored. Investigate the store; re-establish the baseline under a new tag.
            """
        case .symlinkInStore(let p):
            return """
            refusing to restore \(p): its copy in the frozen store is a symbolic link. snapshot \
            refuses to freeze a link, so this was not written by baseline -- reading through it \
            would take the bytes from wherever it now points.
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

    /// The directories that were scanned to build `manifest`, normalised and
    /// sorted. Persisted with the manifest because the manifest alone cannot
    /// answer "is this file new since baseline?" — an empty answer means
    /// "nothing new here" and "I never looked here" indistinguishably, and
    /// only the recorded scope tells the two apart.
    public let directories: [String]

    public init(manifest: [String: String], directories: [String] = []) {
        self.manifest = manifest
        self.directories = directories
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

    /// Number of directory entries pointing at this inode, or `nil` when
    /// there is nothing at `url` at all.
    ///
    /// Fail-closed, via `lstat` directly rather than `attributesOfItem`, so
    /// that "the file is not there" can be told apart from "the file is there
    /// and I could not read it". The first is the ordinary case of restoring
    /// a file the agent deleted. The second means we do not know what the
    /// write is about to land on, which is a refusal. Collapsing both into a
    /// default of 1 is fail-open, and a fail-open branch in a security check
    /// is a bug waiting for the day something makes it reachable.
    private static func linkCount(of url: URL, relative rel: String) throws -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            // ENOENT: no such file. ENOTDIR: a component of the path is not a
            // directory, so likewise nothing is there under that name.
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw FrozenError.unreadableDestination(rel)
        }
        return Int(info.st_nlink)
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
    /// SHA-256, along with the directory list itself. Refuses if any of the
    /// files is a symbolic link, or if any directory on the way to one is.
    public static func snapshot(
        repo: URL, directories: [String], into store: URL
    ) throws -> FrozenSnapshot {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let scope = try normalized(directories: directories)
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
        return FrozenSnapshot(manifest: manifest, directories: scope)
    }

    /// Validates a directory list and puts it in a canonical form, so that
    /// `["Tests/DemoTests/"]` and `["Tests/DemoTests"]` are recognised as the
    /// same scope and ordering never matters.
    private static func normalized(directories: [String]) throws -> [String] {
        try Set(directories.map { try checked(relative: $0) }).sorted()
    }

    // MARK: - Restore

    /// Writes every frozen file back over the repository, erasing whatever
    /// the agent did to it.
    ///
    /// The explicit refusals below are the primary security boundary. The
    /// atomic write is defence in depth behind them, and the two cover
    /// different things, which is the part worth being precise about:
    ///
    /// - Against a symbolic link at the **leaf**, `.atomic` helps. It writes
    ///   a temporary file and renames it into place, so it replaces the link
    ///   rather than following it. `symlinkAtRestore` is still checked first,
    ///   because silently replacing an agent's link is not the behaviour we
    ///   want — noticing it and stopping the run is.
    /// - Against a symbolic link at an **ancestor directory**, `.atomic` does
    ///   nothing at all. The temporary file is created at `dirname(dst)`, and
    ///   the kernel resolves that path through the link before `.atomic` gets
    ///   to do anything, so the temporary file is created outside the
    ///   repository and the rename replaces a file outside the repository.
    ///   `checkAncestors` is therefore fully load-bearing: it is the only
    ///   thing standing between an agent that swaps `Tests/` for a link and
    ///   an arbitrary-file-overwrite primitive running unattended on the
    ///   operator's machine. Measured, both ways round, in `docs/run-log.md`.
    ///
    /// `.atomic` also makes each file all-or-nothing, so a process killed
    /// mid-restore cannot leave a half-written frozen file behind.
    ///
    /// A refusal aborts the whole restore, which can leave earlier files
    /// already written back — whole files, not torn ones. That is intended:
    /// the caller treats a restore failure as a hard abort of the run, and
    /// restore is idempotent, so the next attempt after the operator has
    /// investigated starts clean.
    public func restore(repo: URL, from store: URL) throws {
        // ---- PASS 1: verify the store, write nothing ----
        //
        // THE STORE IS NOT TRUSTED. It lives outside the repository, which is
        // what keeps an agent that only edits the repository away from it --
        // but it is same-user, 0755/0644, and the agent has a shell. Until
        // this pass existed, `restore` copied the store's bytes into the
        // repository without ever comparing them to the `manifest[rel]`
        // SHA-256 it was already carrying, so one `sed -i` on the stored
        // benchmark made `eval` install the attacker's benchmark and then
        // measure it (rc=0, ratio 0.00247, and the repository afterwards
        // contained the attacker's file). The manifest is the record of what
        // was frozen; the store is a cache of the bytes.
        //
        // A SEPARATE PASS, not a check folded into the write loop, so that a
        // tampered file discovered halfway through cannot leave the first half
        // of the frozen set already written back. Either the whole restore is
        // trustworthy or nothing is written. The verified bytes are held here
        // rather than re-read below, because re-reading would reopen exactly
        // the check-then-use window this closes.
        var verified: [(rel: String, data: Data)] = []
        for path in manifest.keys.sorted() {
            let rel = try FrozenSnapshot.checked(relative: path)
            let src = store.appendingPathComponent(rel)
            guard !FrozenSnapshot.isSymlink(src) else {
                throw FrozenError.symlinkInStore(rel)
            }
            let data = try Data(contentsOf: src)
            let actual = FrozenSnapshot.sha256(data)
            // `manifest[path]`, not `manifest[rel]`: `checked` trims trailing
            // slashes, and the manifest is keyed by the untrimmed spelling it
            // was written with.
            guard let expected = manifest[path], actual == expected else {
                throw FrozenError.storeContentMismatch(
                    rel, expected: manifest[path] ?? "<nothing>", actual: actual)
            }
            verified.append((rel: rel, data: data))
        }

        // ---- PASS 2: write ----
        for (rel, data) in verified {
            let dst = repo.appendingPathComponent(rel)

            // Before creating anything: `createDirectory` happily follows a
            // symlinked ancestor and would materialise the run's directory
            // tree outside the repository.
            try FrozenSnapshot.checkAncestors(repo: repo, relative: rel)
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Check BEFORE writing. A link planted after baseline must fail loudly.
            guard !FrozenSnapshot.isSymlink(dst) else { throw FrozenError.symlinkAtRestore(rel) }
            if let links = try FrozenSnapshot.linkCount(of: dst, relative: rel), links > 1 {
                throw FrozenError.hardLinkAtRestore(rel)
            }
            try data.write(to: dst, options: .atomic)
        }
    }

    // MARK: - New files

    /// Files present under the frozen directories now that were not in the
    /// manifest at baseline. SwiftPM compiles a new file in an existing test
    /// target with no `Package.swift` edit, so an unnoticed new file is a way
    /// to add a passing test that shadows a frozen failing one.
    ///
    /// This is the form callers should prefer: the scope comes from what
    /// baseline recorded, so there is no way to ask the question at a scope
    /// baseline never froze.
    public func newFiles(repo: URL) throws -> [String] {
        try FrozenSnapshot.files(in: repo, directories: directories)
            .filter { manifest[$0] == nil }
    }

    /// As `newFiles(repo:)`, for a caller that has its own copy of the
    /// directory list, and refusing loudly if that copy disagrees with the
    /// recorded one.
    ///
    /// A silently narrower list is the dangerous case: the dropped
    /// directories are simply never scanned, so nothing in them is ever
    /// reported as new and the gate shrinks without any symptom. Comparison
    /// is on the normalised, sorted lists, so spelling and ordering do not
    /// matter — only the actual scope does.
    public func newFiles(repo: URL, directories: [String]) throws -> [String] {
        let requested = try FrozenSnapshot.normalized(directories: directories)
        guard requested == self.directories else {
            throw FrozenError.directoriesMismatch(
                recorded: self.directories, requested: requested)
        }
        return try newFiles(repo: repo)
    }

    // MARK: - Persistence

    /// Writes the manifest, and the scope it was taken at, as JSON.
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
        for directory in snapshot.directories { try checked(relative: directory) }
        return snapshot
    }
}
