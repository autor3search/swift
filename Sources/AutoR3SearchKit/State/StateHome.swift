import Foundation
import Crypto

/// Everything the KEEP/DISCARD metric depends on lives outside the repository
/// under test, keyed by a hash of the repository's absolute path. An AI agent
/// edits the repository under test; anything it can write, it will eventually
/// write. If the frozen test snapshots, the baseline record, or the pinned
/// worktree lived in-repo, tampering with them would make every experiment
/// return KEEP.
public enum StateHomeError: Error, CustomStringConvertible {
    /// `AUTOR3SEARCH_SWIFT_STATE_HOME` was set to a relative path. Every
    /// command accepts `-C <dir>` and does not chdir, so a relative override
    /// would resolve against whatever directory each command happened to be
    /// invoked from — `eval` run from a subdirectory and `stop` run from the
    /// repository root would then address DIFFERENT state for the SAME run.
    case relativeOverride(String)

    /// `tag` (typically typed by the operator via `--tag <name>`) is not a
    /// safe single path component. In particular a tag containing `..` — as
    /// a whole component, or via an embedded `/` — would, once the URL is
    /// standardized on any real file I/O, escape `root` and could resolve
    /// anywhere on the filesystem, including back inside the repository
    /// under test. That defeats the reason state lives outside the repo at
    /// all, so tags are validated once, here, before any accessor builds a
    /// path from one.
    case invalidTag(String)

    public var description: String {
        switch self {
        case .relativeOverride(let value):
            return """
            AUTOR3SEARCH_SWIFT_STATE_HOME must be an absolute path, got "\(value)". A relative \
            value resolves against whatever directory each command happens to run from, so \
            eval from a subdirectory and stop from the repository root would address \
            different state for the same run.
            """
        case .invalidTag(let value):
            return """
            "\(value)" is not a valid run tag. A tag must be a single path component: only \
            ASCII letters, digits, "-", "_", and "." are allowed, it must not be empty, must \
            not contain "/" or "\\\\", and must not be "." or "..". Examples of valid tags: \
            "sep16", "2026-09-16", "sep16_v2".
            """
        }
    }
}

/// The root of all state for a single repository under test, resolved
/// outside that repository so nothing the agent edits can influence it.
public struct StateHome {
    public let root: URL

    /// The repository directory's own name, used as the pinned worktree's
    /// leaf directory. See `worktreeURL(tag:)` for why that matters and is
    /// not cosmetic.
    public let repoDirectoryName: String

    /// The container the pinned worktree is created inside. Kept as a fixed
    /// name so the worktree can never collide with a sibling state entry
    /// (`frozen/`, `baseline.json`, `run.claim`) whatever the repository
    /// happens to be called.
    public static let worktreeContainer = "baseline-worktree"

    public static let envKey = "AUTOR3SEARCH_SWIFT_STATE_HOME"

    public init(repo: URL, env: [String: String]) throws {
        let base: URL
        if let override = env[StateHome.envKey], !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw StateHomeError.relativeOverride(override)
            }
            base = URL(fileURLWithPath: override)
        } else {
            let cache = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            base = cache.appendingPathComponent("autor3search-swift")
        }
        let absolutePath = repo.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(absolutePath.utf8))
        let key = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        self.root = base.appendingPathComponent(String(key))
        // Held to the same single-component rule as a run tag, and for the
        // same reason: it becomes a directory name. A repository directory
        // whose name does not satisfy it falls back to a fixed literal --
        // which is exactly the situation that existed for every repository
        // before `worktreeURL` used this at all, so the fallback loses
        // nothing that was previously had.
        let name = repo.standardizedFileURL.lastPathComponent
        self.repoDirectoryName = StateHome.PathComponent.isSafe(name) ? name : "repo"
    }

    /// Every other accessor funnels through this one. Validating the tag
    /// here, once, means a malformed tag is rejected in exactly one place —
    /// seven independent per-accessor checks would be seven chances to miss
    /// one, the same class of mistake the "every accessor" test guards
    /// against for the out-of-repo property itself.
    public func runDir(tag: String) throws -> URL {
        root.appendingPathComponent(try Self.validated(tag: tag))
    }

    public func baselineRecordURL(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent("baseline.json")
    }

    public func frozenDir(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent("frozen")
    }

    /// The pinned measurement worktree: a checkout of `measurementCommit`,
    /// inside a fixed `baseline-worktree/` container, in a directory named
    /// AFTER THE REPOSITORY.
    ///
    /// ## Why the leaf is the repository's name and not a literal
    ///
    /// This used to be `<run>/baseline-worktree` and nothing else, and that
    /// silently made the nested-benchmark-package layout unbuildable on the
    /// baseline side. **SwiftPM derives a path dependency's package IDENTITY
    /// from its directory name.** A nested benchmark package says
    ///
    /// ```swift
    /// dependencies: [.package(path: "../"), .package(url: ".../package-benchmark", ...)]
    /// targets: [.executableTarget(name: "SwiftASN1Benchmark", dependencies: [
    ///     .product(name: "SwiftASN1", package: "swift-asn1"), ...
    /// ```
    ///
    /// — naming the root package `swift-asn1`, which is the CHECKOUT
    /// DIRECTORY's name. In a worktree called `baseline-worktree`, `../`
    /// resolves to identity `baseline-worktree`, and SwiftPM refuses:
    ///
    /// ```
    /// error: 'benchmarks': unknown package 'swift-asn1' in dependencies of
    /// target 'SwiftASN1Benchmark'; valid packages are: 'baseline-worktree'
    /// (at .../nested1/baseline-worktree), 'package-benchmark'
    /// ```
    ///
    /// Measured, on a real `apple/swift-asn1` clone: `baseline` completed but
    /// both warm builds failed with exactly that, and `eval` would then have
    /// answered `baseline_benchmark_build_failed` forever -- there is nothing
    /// to measure the candidate against, and no configuration change can fix
    /// it, because the offending name is the harness's own. The candidate side
    /// was unaffected (its directory IS the repository), so this is one of
    /// those defects that is invisible until the second of two sides is tried
    /// -- the shape SECURITY.md's "anything with a symmetry" note warns about.
    ///
    /// Unconditional, not conditional on the layout: one geometry for every
    /// repository is worth more than saving one directory level for the ones
    /// that do not need it, and a path that changes shape depending on the
    /// config is a path two code paths will eventually disagree about.
    ///
    /// ## Migration
    ///
    /// A run baselined under the previous layout has its worktree one level
    /// up, at `<run>/baseline-worktree`, and nothing is registered at the new
    /// path. `eval` detects exactly that and refuses with a message naming
    /// the fix, rather than failing to restore a worktree that is not there.
    /// Re-run `baseline` under a NEW tag -- the same answer this project
    /// already gives for every record written before an inventory existed
    /// (see `baseline_predates_tree_inventory`).
    public func worktreeURL(tag: String) throws -> URL {
        try runDir(tag: tag)
            .appendingPathComponent(StateHome.worktreeContainer)
            .appendingPathComponent(repoDirectoryName)
    }

    /// Where a run baselined before the worktree was named after the
    /// repository put its checkout. Read ONLY to produce a legible refusal;
    /// nothing is ever built, restored or measured out of it.
    public func legacyWorktreeURL(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent(StateHome.worktreeContainer)
    }

    public func benchStorageURL(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent("bench-storage")
    }

    public func runClaimURL(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent("run.claim")
    }

    public func stopRequestURL(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent("stop.request")
    }

    /// What makes a string safe to use as ONE path component.
    ///
    /// Extracted from `validated(tag:)` so the identical rule can be applied
    /// per-component to a repo-relative path (`benchmark_package_path`, via
    /// `BenchmarkPackage.validateShape`) without being written out a second
    /// time. Two spellings of this rule would be two rules to keep in step,
    /// and the gap between them is where a `..` gets through.
    ///
    /// The rule itself is unchanged: ASCII letters, digits, `-`, `_`, `.`,
    /// non-empty, and never `.` or `..` in whole. `.` is allowed INSIDE a
    /// component for dates (`2026-09-16`) and for dot-directories, but a
    /// component that is entirely `.` or `..` denotes the directory itself or
    /// its parent, and once any URL built from it is standardized on real
    /// file I/O that is an escape.
    public enum PathComponent {
        /// ASCII letters, digits, `-`, `_`, `.`.
        public static let allowedCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")

        public static func isSafe(_ component: String) -> Bool {
            guard !component.isEmpty, component != ".", component != ".." else { return false }
            return component.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
        }
    }

    private static func validated(tag: String) throws -> String {
        guard PathComponent.isSafe(tag) else { throw StateHomeError.invalidTag(tag) }
        return tag
    }
}
