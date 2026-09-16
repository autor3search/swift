import Foundation

/// A git plumbing command failed. Unlike a benchmark or test subprocess
/// (where a non-zero exit is *data*), a failing git command genuinely means
/// something is wrong — the harness cannot proceed without a working repo.
public enum GitError: Error, CustomStringConvertible {
    case command(String, Int32, String)

    /// Output was capped mid-stream (`ProcessDataResult.outputTruncated`)
    /// for a command whose caller needs the complete, exact bytes —
    /// `fileContents` and `changedPaths`. Returning the truncated prefix as
    /// though it were complete would be silent data corruption, which this
    /// project exists to avoid; this makes it a loud failure instead.
    case truncated(String)

    public var description: String {
        switch self {
        case .command(let args, let rc, let stderr):
            return "git \(args) exited \(rc): \(stderr)"
        case .truncated(let args):
            return "git \(args) output was truncated (exceeded the capture cap) — refusing to return partial data"
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

    /// `-z` disables `core.quotePath`'s C-style octal-escaping of non-ASCII
    /// filenames (a plain `--name-only` would return `"caf\303\251.swift"`,
    /// a 16-character quoted literal, for `café.swift` — not a path Task
    /// 17's scope gate could ever match against the real filesystem) and
    /// emits raw, unescaped UTF-8 bytes with each path NUL-terminated
    /// instead of newline-separated. `--no-renames` disables rename
    /// detection so a rename reports as an explicit deletion of the old
    /// path plus an addition of the new one, rather than only the new path
    /// — rename-detection defaults are git-version and config dependent, so
    /// leaving them on would also make this non-deterministic across
    /// machines.
    ///
    /// Goes through `Subprocess.runData`, NOT `Git.run` — `run` trims the
    /// *whole* decoded String with `.trimmingCharacters(in:
    /// .whitespacesAndNewlines)` before this function would ever get to
    /// split it, which would silently eat a leading space from the first
    /// path in the output. Splitting the raw bytes on the 0x00 terminator
    /// and decoding each path from its own byte slice means no String-level
    /// trimming ever touches path data, so a leading or trailing space
    /// inside a real filename survives intact. Also checks
    /// `outputTruncated`, for the same reason `fileContents` does below: a
    /// silently truncated file list would silently drop paths from Task
    /// 17's scope gate rather than fail loudly.
    public func changedPaths(since commit: String) throws -> [String] {
        let args = ["diff", "-z", "--no-renames", "--name-only", commit, "HEAD"]
        let result = try Subprocess.runData(Git.gitBinary, args, cwd: repo, env: nil, timeout: 120)
        guard result.exitCode == 0 else {
            throw GitError.command(args.joined(separator: " "), result.exitCode, result.stderr)
        }
        guard !result.outputTruncated else {
            throw GitError.truncated(args.joined(separator: " "))
        }
        return result.stdout
            .split(separator: 0x00)
            .map { String(decoding: $0, as: UTF8.self) }
            .sorted()
    }

    /// Returns the exact bytes of `path` as it existed at `commit`. Uses
    /// `Subprocess.runData`, not `run`, so binary content or a file saved in
    /// a non-UTF-8 encoding round-trips exactly — `run`'s `String` decoding
    /// silently repairs invalid byte sequences to U+FFFD, which would
    /// corrupt the blob before this function ever saw it.
    ///
    /// Also refuses a truncated read: `runData`'s default `outputCapBytes`
    /// (4 MiB) would otherwise let a larger blob come back silently
    /// half-written, indistinguishable from a complete, small file — the
    /// exact class of silent corruption this project exists to catch.
    public func fileContents(_ path: String, at commit: String) throws -> Data {
        try fileContents(path, at: commit, outputCapBytes: 4 << 20)
    }

    /// Test-only entry point for binding the truncation guard above without
    /// exposing a cap parameter on the public, fixed-interface
    /// `fileContents(_:at:)` — an explicit small cap on a modest blob is the
    /// cheap way to make `outputTruncated` actually trip in a test.
    func fileContents(_ path: String, at commit: String, outputCapBytes: Int) throws -> Data {
        let result = try Subprocess.runData(
            Git.gitBinary, ["show", "\(commit):\(path)"], cwd: repo, env: nil, timeout: 60,
            outputCapBytes: outputCapBytes)
        guard result.exitCode == 0 else {
            throw GitError.command("show \(commit):\(path)", result.exitCode, result.stderr)
        }
        guard !result.outputTruncated else {
            throw GitError.truncated("show \(commit):\(path)")
        }
        return result.stdout
    }

    /// For `version`: the commit of a checkout build. `nil` if HEAD cannot be
    /// resolved (e.g. not a git checkout at all), rather than throwing —
    /// version reporting must not fail just because it can't find git info.
    public func describeShort() throws -> String? {
        guard let sha = try? run(["rev-parse", "--short", "HEAD"]) else { return nil }
        return sha
    }
}
