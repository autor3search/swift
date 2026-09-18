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

    /// Prefixed to EVERY git invocation the harness makes.
    ///
    /// GIT HOOKS ARE CODE THE HARNESS RUNS. `.git/` is in
    /// `neverWalkedDirectories`, git never reports it as a changed or ignored
    /// path, and the hook directory is SHARED with every linked worktree -- so
    /// a `post-checkout` hook planted in the repository under test fires inside
    /// `Worktree.restoreToPin`'s own `git checkout --detach --force`, after the
    /// restore has happened. Measured: the hook re-set `--skip-worktree` and
    /// rewrote an out-of-scope helper, and the eval returned
    /// `rc 0, keep, ratio 0.10045, warnings: []` -- silent, because
    /// `indexFlaggedPaths` had been sampled BEFORE the checkout and `git
    /// status` was then lied to by the flag.
    ///
    /// DENY, DO NOT DELETE. Emptying `.git/hooks` would not have helped:
    /// `core.hooksPath` can be set from the ENVIRONMENT with
    /// `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath`, writing nothing
    /// under `.git/` at all -- measured at `rc 0, keep, ratio 0.09985`. A `-c`
    /// on the command line outranks every configuration source including that
    /// one; verified both ways round:
    ///
    /// ```
    /// GIT_CONFIG_COUNT=1 ... git -c core.hooksPath=/dev/null checkout --force  -> hook did NOT run
    /// GIT_CONFIG_COUNT=1 ... git                              checkout --force  -> hook RAN
    /// ```
    ///
    /// `/dev/null` rather than an empty directory the harness creates: an empty
    /// directory is same-user and could simply have hooks written into it,
    /// whereas `<path>/post-checkout` under `/dev/null` cannot resolve on any
    /// POSIX system. Verified to exit 0 and run no hook.
    /// EVERY CONFIGURATION KEY THAT MAKES GIT RUN A PROGRAM, denied on every
    /// invocation the harness makes.
    ///
    /// THE DEFECT THIS REPLACES was not the missing key; it was how the list
    /// was built. Round 5 denied `core.hooksPath` because a hook was the vector
    /// that had been found, and stopped there. `core.fsmonitor` is a SEPARATE
    /// code-execution config, `.git/config` is excluded from every content gate
    /// by design, and core config is shared with the linked worktree -- so an
    /// agent's fsmonitor ran inside gate 7's own git calls, 22 times an eval,
    /// and overwrote the baseline binary during the post-build `status` that
    /// sits between the build and `MeasuredBinaryGuard`'s snapshot. Measured
    /// 2/2 at ratio 0.0496 and 0.0495. A list built from the last attack will
    /// always be one attack behind; this one is built from `git config`'s own
    /// documentation for the installed version (2.54.0).
    ///
    /// MEASURED, not assumed. `core.fsmonitor` was observed firing on
    /// `status --porcelain`, `status --porcelain -z --ignored`, `ls-files -v`,
    /// `checkout --detach --force` and `add` -- five of the commands this type
    /// runs -- and `-c core.fsmonitor=false` was observed to deny all five.
    /// `diff.external` fires on a content `git diff` but NOT on `--name-only`,
    /// and `-c diff.external=` denies it.
    ///
    /// Keys whose trigger conditions this harness never reaches are denied
    /// anyway: they cost one argument each, and "we do not run that command
    /// today" is exactly the reasoning that left `core.fsmonitor` open.
    private static let executionDenials: [(key: String, value: String)] = [
        // Hooks, and the file-system monitor that is NOT a hook.
        ("core.hooksPath", "/dev/null"),
        ("core.fsmonitor", "false"),
        // Programs git will run for refs, transport and credentials.
        ("core.alternateRefsCommand", ""),
        ("core.sshCommand", ""),
        ("core.gitProxy", ""),
        ("core.askPass", ""),
        ("credential.helper", ""),
        // Programs git will run to show things to a human. Never reached with
        // no tty, which is precisely why they are easy to forget.
        ("core.pager", "cat"),
        ("core.editor", ""),
        ("sequence.editor", ""),
        // External diff. `--name-only` does not use it; a content diff does.
        ("diff.external", ""),
        ("interactive.diffFilter", ""),
        // Signing, reachable if a repository sets `commit.gpgSign`.
        ("gpg.program", ""),
        ("gpg.openpgp.program", ""),
        ("gpg.x509.program", ""),
        ("gpg.ssh.program", ""),
        ("gpg.ssh.defaultKeyCommand", ""),
        // Maintenance and server-side hooks that ordinary commands can trigger.
        ("gc.recentObjectsHook", ""),
        ("uploadpack.packObjectsHook", ""),
        // NOT execution, but the out-of-tree door to the filter and ignore
        // machinery that IS execution. An in-tree `.gitattributes` still
        // applies; this only closes the file an agent could point git at.
        ("core.attributesFile", "/dev/null"),
        ("core.excludesFile", "/dev/null"),
    ]

    /// What `-c` CANNOT deny, because the keys are per-name and a wildcard is
    /// not accepted: `filter.<name>.clean`, `filter.<name>.smudge`,
    /// `filter.<name>.process`, `diff.<name>.textconv`, `diff.<name>.command`,
    /// `pager.<cmd>`, `trailer.<key>.cmd`, and the `difftool`/`mergetool`/
    /// `guitool`/`man`/`browser` `<tool>.cmd` families.
    ///
    /// Measured: a `filter.zz.smudge` DOES fire on `checkout --detach --force`,
    /// and is denied only when the driver's name is spelled out. Enumerating
    /// the names out of the repository's own config would be a
    /// check-then-use race, since the same agent can add one afterwards.
    ///
    /// What covers the reachable half of that gap is not this list at all:
    /// `Worktree.contentMismatches` hashes the worktree's bytes against the
    /// blob ids in the commit and asks git nothing, so a smudge filter that
    /// rewrites a file during the restore is caught by content even though the
    /// filter itself ran. That is genuine coverage for the worktree, and it is
    /// NOT coverage for the candidate repository, which has no such comparison
    /// -- see the run log's residual list.
    static let undeniableWildcardFamilies = [
        "filter.<name>.clean", "filter.<name>.smudge", "filter.<name>.process",
        "diff.<name>.textconv", "diff.<name>.command", "pager.<cmd>",
        "trailer.<key>.cmd", "difftool.<tool>.cmd", "mergetool.<tool>.cmd",
    ]

    /// Git's own arguments, plus the denials. Kept separate from the caller's
    /// `args` so diagnostics still quote the command the caller asked for
    /// rather than the harness's plumbing.
    private static func hardened(_ args: [String]) -> [String] {
        executionDenials.flatMap { ["-c", "\($0.key)=\($0.value)"] } + args
    }

    /// The denied keys, for the test that pins the list. Exposed rather than
    /// re-derived so widening it is a deliberate edit in two places.
    static var executionDenialKeys: [String] { executionDenials.map(\.key) }

    /// Runs a git subcommand against `cwd` (defaulting to `repo`) and returns
    /// trimmed stdout. A non-zero exit throws `GitError.command` — for git
    /// plumbing, that genuinely is an error, not data to be scored.
    @discardableResult
    public func run(_ args: [String], cwd: URL? = nil, timeout: TimeInterval = 120) throws -> String {
        let result = try Subprocess.run(
            Git.gitBinary, Git.hardened(args), cwd: cwd ?? repo,
            env: SanitizedEnvironment.forTools(), timeout: timeout)
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

    /// One line of `git status --porcelain`.
    ///
    /// `code` is the raw two-character XY field, kept verbatim rather than
    /// decoded into an enum: the only distinction any caller here needs is
    /// "is this `!!`", and reproducing git's full status algebra would be a
    /// second, subtly different definition of the same thing.
    public struct StatusEntry: Sendable, Equatable {
        /// The two-character XY status field, e.g. `" M"`, `"??"`, `"!!"`.
        public let code: String

        /// Repository-relative path, byte-exact and unquoted (see `status`).
        ///
        /// A TRAILING SLASH IS SIGNIFICANT and is preserved. `git status
        /// --ignored` (traditional mode, the default) collapses a directory
        /// every one of whose entries is ignored into a single record for the
        /// directory -- `!! .build/` rather than one line per object file.
        /// Callers must therefore match a trailing-slash path as "this
        /// directory and everything in it", not as a file name.
        public let path: String

        /// For a rename or copy (`R`/`C`), the path it came from. git emits
        /// that as a SECOND NUL-terminated record with no status prefix of
        /// its own, so a parser that does not know to consume it reads the
        /// old path as a malformed entry.
        public let originalPath: String?

        /// `!!` -- present on disk, and hidden from an ordinary `git status`
        /// by `.gitignore`, `.git/info/exclude`, a global excludes file or
        /// `core.excludesFile`. All four are ignore sources; none of them is
        /// visible in `git status --porcelain` without `--ignored`.
        public var isIgnored: Bool { code == "!!" }
    }

    /// `git status --porcelain`, parsed, optionally INCLUDING ignored files.
    ///
    /// WHY `--ignored` EXISTS AS AN OPTION HERE. `git status --porcelain`
    /// omits ignored files entirely, and that omission was a live bypass of
    /// the dirty-tree gate. The agent under measurement controls the ignore
    /// rules: it can commit an in-scope `Sources/Demo/.gitignore` naming
    /// `*.gen.swift` (in scope, not a manifest, so the scope gate passes),
    /// or write `.git/info/exclude`, which is not a repository file at all
    /// and cannot be committed, reviewed or gated by path. Either way it can
    /// then plant a source file that `git status --porcelain` reports as
    /// nothing while `swift build` compiles it. Because the pinned
    /// measurement worktree is a checkout of a COMMIT, the planted file
    /// exists only on the candidate side, so it manufactures a win on EVERY
    /// later eval, credited to commits that do not contain it -- and neither
    /// `git add -A` nor `git reset --hard` disturbs it.
    ///
    /// Uses `runData` with `-z` for exactly the reasons `changedPaths`
    /// documents: `-z` turns off `core.quotePath`'s octal escaping so a
    /// non-ASCII filename arrives as real UTF-8 bytes rather than a quoted
    /// literal, and splitting the raw bytes means `run`'s whole-output
    /// trimming never eats a leading space from a real filename. A truncated
    /// capture throws rather than silently dropping records -- dropping one
    /// here would drop the refusal it was supposed to cause.
    ///
    /// `--ignored` is left at git's default TRADITIONAL mode on purpose, not
    /// `--ignored=matching`: traditional collapses a wholly-ignored directory
    /// to one record, so `.build/` is a single line instead of the several
    /// thousand `--ignored=matching` would emit for a warm build -- which
    /// would be slower and would risk tripping the truncation guard above on
    /// every single eval.
    public func status(includingIgnored: Bool = false) throws -> [StatusEntry] {
        var args = ["status", "--porcelain", "-z"]
        if includingIgnored { args.append("--ignored") }
        let result = try Subprocess.runData(
            Git.gitBinary, Git.hardened(args), cwd: repo,
            env: SanitizedEnvironment.forTools(), timeout: 120)
        guard result.exitCode == 0 else {
            throw GitError.command(args.joined(separator: " "), result.exitCode, result.stderr)
        }
        guard !result.outputTruncated else {
            throw GitError.truncated(args.joined(separator: " "))
        }
        let records = result.stdout
            .split(separator: 0x00, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }

        var entries: [StatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            // "XY PATH": two status characters, one space, then the path.
            // Anything shorter cannot be a record and is skipped rather than
            // force-unwrapped into a crash.
            guard record.count > 3 else { continue }
            let code = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            var original: String?
            if code.first == "R" || code.first == "C" || code.dropFirst().first == "R"
                || code.dropFirst().first == "C" {
                // Verified against git 2.x: `git mv a.txt c.txt` emits
                // "R  c.txt\0a.txt\0" -- the NEW path in the status record,
                // the ORIGINAL as a bare follow-on record.
                if index < records.count {
                    original = records[index]
                    index += 1
                }
            }
            entries.append(StatusEntry(code: code, path: path, originalPath: original))
        }
        return entries
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
        let result = try Subprocess.runData(
            Git.gitBinary, Git.hardened(args), cwd: repo,
            env: SanitizedEnvironment.forTools(), timeout: 120)
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
            Git.gitBinary, Git.hardened(["show", "\(commit):\(path)"]), cwd: repo,
            env: SanitizedEnvironment.forTools(), timeout: 60,
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
