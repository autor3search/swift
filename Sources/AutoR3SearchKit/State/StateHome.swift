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

    public var description: String {
        switch self {
        case .relativeOverride(let value):
            return """
            AUTOR3SEARCH_SWIFT_STATE_HOME must be an absolute path, got "\(value)". A relative \
            value resolves against whatever directory each command happens to run from, so \
            eval from a subdirectory and stop from the repository root would address \
            different state for the same run.
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

    public func runDir(tag: String) -> URL {
        root.appendingPathComponent(tag)
    }

    public func baselineRecordURL(tag: String) -> URL {
        runDir(tag: tag).appendingPathComponent("baseline.json")
    }

    public func frozenDir(tag: String) -> URL {
        runDir(tag: tag).appendingPathComponent("frozen")
    }

    public func worktreeURL(tag: String) -> URL {
        runDir(tag: tag).appendingPathComponent("baseline-worktree")
    }

    public func benchStorageURL(tag: String) -> URL {
        runDir(tag: tag).appendingPathComponent("bench-storage")
    }

    public func runClaimURL(tag: String) -> URL {
        runDir(tag: tag).appendingPathComponent("run.claim")
    }

    public func stopRequestURL(tag: String) -> URL {
        runDir(tag: tag).appendingPathComponent("stop.request")
    }
}
