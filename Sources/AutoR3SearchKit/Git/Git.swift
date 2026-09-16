import Foundation

/// A git plumbing command failed. Unlike a benchmark or test subprocess
/// (where a non-zero exit is *data*), a failing git command genuinely means
/// something is wrong — the harness cannot proceed without a working repo.
public enum GitError: Error, CustomStringConvertible {
    case command(String, Int32, String)

    public var description: String {
        switch self {
        case .command(let args, let rc, let stderr):
            return "git \(args) exited \(rc): \(stderr)"
        }
    }
}

/// Thin wrapper over the `git` binary, scoped to one repository. Every
/// command is run with an explicit `cwd` (never an inherited working
/// directory) and never relies on git prompting — stdin is redirected to
/// /dev/null by `Subprocess`, so any interactive prompt fails closed instead
/// of hanging.
public struct Git: Sendable {
    public let repo: URL

    public init(repo: URL) {
        self.repo = repo
    }

    private static let gitBinary = URL(fileURLWithPath: "/usr/bin/git")

    /// Runs a git subcommand against `cwd` (defaulting to `repo`) and returns
    /// trimmed stdout. A non-zero exit throws `GitError.command` — for git
    /// plumbing, that genuinely is an error, not data to be scored.
    @discardableResult
    public func run(_ args: [String], cwd: URL? = nil, timeout: TimeInterval = 120) throws -> String {
        let result = try Subprocess.run(Git.gitBinary, args, cwd: cwd ?? repo, env: nil, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GitError.command(args.joined(separator: " "), result.exitCode, result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func head() throws -> String {
        try run(["rev-parse", "HEAD"])
    }

    public func currentBranch() throws -> String {
        try run(["rev-parse", "--abbrev-ref", "HEAD"])
    }

    public func isClean() throws -> Bool {
        try run(["status", "--porcelain"]).isEmpty
    }

    public func createBranch(_ name: String) throws {
        try run(["checkout", "-q", "-b", name])
    }

    public func branchExists(_ name: String) -> Bool {
        (try? run(["rev-parse", "--verify", name])) != nil
    }

    public func changedPaths(since commit: String) throws -> [String] {
        let output = try run(["diff", "--name-only", commit, "HEAD"])
        return output.isEmpty ? [] : output.split(separator: "\n").map(String.init).sorted()
    }

    public func fileContents(_ path: String, at commit: String) throws -> Data {
        let result = try Subprocess.run(Git.gitBinary, ["show", "\(commit):\(path)"], cwd: repo, env: nil, timeout: 60)
        guard result.exitCode == 0 else {
            throw GitError.command("show \(commit):\(path)", result.exitCode, result.stderr)
        }
        return Data(result.stdout.utf8)
    }

    /// For `version`: the commit of a checkout build. `nil` if HEAD cannot be
    /// resolved (e.g. not a git checkout at all), rather than throwing —
    /// version reporting must not fail just because it can't find git info.
    public func describeShort() throws -> String? {
        guard let sha = try? run(["rev-parse", "--short", "HEAD"]) else { return nil }
        return sha
    }
}
