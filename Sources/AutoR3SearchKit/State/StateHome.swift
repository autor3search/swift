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

    public func worktreeURL(tag: String) throws -> URL {
        try runDir(tag: tag).appendingPathComponent("baseline-worktree")
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

    /// ASCII letters, digits, `-`, `_`, `.` — the family of tags the brief
    /// documents (`sep16`, `2026-09-16`, `sep16_v2`). `.` is included for
    /// dates but a tag that is entirely `.` or `..` is still rejected below,
    /// since as a whole path component either would resolve to `root` itself
    /// or escape it to `root`'s parent.
    private static let allowedTagCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")

    private static func validated(tag: String) throws -> String {
        guard !tag.isEmpty,
              tag != ".", tag != "..",
              tag.unicodeScalars.allSatisfy({ allowedTagCharacters.contains($0) })
        else {
            throw StateHomeError.invalidTag(tag)
        }
        return tag
    }
}
