// Sources/AutoR3SearchKit/SwiftPM/Lockfile.swift
//
// EVERYTHING THIS PROJECT KNOWS ABOUT `Package.resolved`, IN ONE PLACE.
//
// `Package.resolved` is the only artefact SwiftPM writes into the repository
// ROOT (not `.build/`) as a side effect of ordinary work, and that single fact
// produced a defect that bricked every repository with external dependencies:
//
//   - `swift package describe --type json` -- all `init` used to run -- exits 0
//     and does NOT write `Package.resolved`.
//   - `swift build -c release --product <X>` DOES write it, into the package
//     root. `--scratch-path` does not move it.
//   - So `baseline` (which only ever ran `describe` before hashing) recorded the
//     hash of a file that did not exist, and the FIRST `eval`'s own build then
//     created it.
//   - From then on, permanently: committing it trips `ScopeGate.isManifestPath`
//     (`manifest_change_rejected`); leaving it uncommitted trips gate 2b
//     (`dirty_working_tree`). `frozenCommit` never advances, so neither door
//     ever reopens.
//
// The fix is to make the lockfile exist and be TRACKED before the freeze, and
// to make "there is no lockfile" a state the harness can tell apart from "the
// lockfile is empty" -- see `absentPin` and `emptyDataSHA256` below.
//
// MEASURED FACTS (this file's behaviour rests on them; every one was run, not
// read -- see docs/run-log.md for the captured transcripts, machine named
// there):
//
//   | package shape                            | describe | resolve | build | lockfile |
//   |------------------------------------------|----------|---------|-------|----------|
//   | no dependencies at all                   | rc 0     | rc 0    | rc 0  | NEVER    |
//   | `.package(path:)` only (type fileSystem) | rc 0     | rc 0    | rc 0  | NEVER    |
//   | `.package(url:)` (type sourceControl)    | rc 0     | rc 0    | rc 0  | resolve+ |
//   | path dep whose OWN manifest has a url dep| rc 0     | rc 0    | rc 0  | resolve+ |
//
// The last row is why `hasExternalDependencies` is NOT the authority here. It
// reads the manifest's DIRECT dependencies, and a `fileSystem` dependency that
// itself pulls a `sourceControl` one makes the root package produce a
// `Package.resolved` while `describe` reports nothing but `fileSystem` at the
// top level -- verified live. `probe` asks SwiftPM instead of guessing, and is
// what both `init` and `baseline` actually decide on.
import Foundation

public enum Lockfile {
    /// The file name, in one place, so no caller spells it by hand.
    public static let name = "Package.resolved"

    /// SHA-256 of zero bytes. This exact string is what the broken
    /// `BaselineRunner.sha256File` recorded in `packageResolvedSHA256` for
    /// every repository that had dependencies but no lockfile -- a
    /// legitimate-looking 64-hex pin that pins nothing at all. `doctor` looks
    /// for it to identify a baseline taken under the broken behaviour.
    public static let emptyDataSHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// What `baseline` records in `packageResolvedSHA256` when the package
    /// genuinely produces no lockfile (no external dependencies anywhere in its
    /// graph -- established by `probe`, not assumed).
    ///
    /// Deliberately NOT a hash, and deliberately not the empty string: the
    /// whole defect above turns on "missing" and "empty" being indistinguishable
    /// once they are both 64 hex characters. This value cannot be confused with
    /// any SHA-256, cannot be produced by hashing anything, and reads as what it
    /// means when a human opens `baseline.json`.
    ///
    /// `BaselineRecord.packageResolvedSHA256` is a non-optional `String` owned by
    /// another part of the tree, so widening it to `String?` is not on the table
    /// here; a sentinel carries the same information without changing a shared
    /// type's shape.
    public static let absentPin = "absent:no-package-resolved"

    /// Whether `pin` is the tell-tale of a baseline taken under the broken
    /// behaviour: dependencies present, no lockfile, hash of nothing recorded as
    /// though it were a real pin.
    public static func isEmptyDataPin(_ pin: String) -> Bool {
        pin.lowercased() == emptyDataSHA256
    }

    public static func url(in repo: URL) -> URL {
        repo.appendingPathComponent(name)
    }

    public static func exists(in repo: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: repo).path)
    }

    // =====================================================================
    // MARK: - The manifest signal (advisory only)
    // =====================================================================

    /// Minimal local decode of the ONE top-level field this needs out of
    /// `swift package describe --type json`: `dependencies`. Deliberately
    /// separate from `PackageDescribe.Raw` rather than widening a shape other
    /// parts of the tree consume as-is -- the same reasoning, and the same
    /// precedent, as `InitRunner.RawTargetGraph`.
    private struct RawDependencies: Decodable {
        struct Dependency: Decodable {
            let identity: String?
            /// Verified values: `sourceControl` for `.package(url:)`,
            /// `fileSystem` for `.package(path:)`. `registry` exists too and is
            /// pinned in `Package.resolved` like `sourceControl`, so the test is
            /// "not fileSystem" rather than an allow-list of the two kinds this
            /// machine happened to produce.
            let type: String?
        }
        /// Optional: treated as absent rather than as a decode failure, so a
        /// future tools-version that stops emitting the key degrades to "cannot
        /// tell from the manifest" instead of breaking `init` outright. On the
        /// toolchain this was verified against the key is always present, and is
        /// `[]` for a package with no dependencies.
        let dependencies: [Dependency]?
    }

    /// The identities of the package's DIRECT dependencies that SwiftPM would
    /// pin in `Package.resolved` -- i.e. every declared dependency whose `type`
    /// is not `fileSystem`.
    ///
    /// ADVISORY, NOT AUTHORITATIVE. It can only under-report, never over-report:
    /// a `fileSystem` dependency whose own manifest declares a `sourceControl`
    /// one makes the ROOT package produce a lockfile while this returns empty
    /// (verified live). Used for wording a diagnosis and for `doctor`'s
    /// reporting; never as the thing a refusal turns on. `probe` is the
    /// authority.
    public static func externalDependencyIdentities(describeJSON: Data) throws -> [String] {
        let raw: RawDependencies
        do {
            raw = try JSONDecoder().decode(RawDependencies.self, from: describeJSON)
        } catch {
            throw PackageDescribeError.failed(
                "could not decode swift package describe output: \(error)")
        }
        return (raw.dependencies ?? [])
            .filter { ($0.type ?? "sourceControl") != "fileSystem" }
            .map { $0.identity ?? "<unnamed>" }
            .sorted()
    }

    /// Runs `swift package describe --type json` purely to read the top-level
    /// `dependencies` array. Advisory; see `externalDependencyIdentities`.
    public static func externalDependencyIdentities(repo: URL, timeout: TimeInterval = 300) throws -> [String] {
        let r = try Subprocess.run(swiftBinary, ["package", "describe", "--type", "json"],
                                   cwd: repo, env: nil, timeout: timeout)
        guard r.exitCode == 0 else { throw PackageDescribeError.failed(r.stderr) }
        guard !r.outputTruncated else {
            throw PackageDescribeError.failed(
                "swift package describe output was truncated at the capture cap")
        }
        guard let start = r.stdout.firstIndex(of: "{") else {
            throw PackageDescribeError.failed("no JSON in output")
        }
        return try externalDependencyIdentities(describeJSON: Data(r.stdout[start...].utf8))
    }

    // =====================================================================
    // MARK: - The empirical signal (authoritative)
    // =====================================================================

    /// What SwiftPM itself says about whether this package needs a lockfile.
    public enum Requirement: Equatable, Sendable {
        /// `swift package resolve` produced a `Package.resolved`. This package
        /// has an external dependency set that must be pinned.
        case required
        /// `swift package resolve` succeeded and produced no `Package.resolved`.
        /// The package has no external dependencies anywhere in its graph; this
        /// is the legitimate, supported, must-keep-working case.
        case notProduced
        /// The question could not be answered -- `resolve` failed to run or
        /// exited non-zero (no network, a private dependency without
        /// credentials, an unreachable URL, a broken manifest). Callers must
        /// fail closed on this rather than treat it as `notProduced`; the whole
        /// class of bug this file exists to prevent is an operation that returns
        /// success with an empty result.
        case undetermined(String)
    }

    private static let swiftBinary = URL(fileURLWithPath: "/usr/bin/swift")

    /// Asks SwiftPM, in `directory`, whether this package produces a lockfile,
    /// by running `swift package resolve` and looking at what is on disk
    /// afterwards.
    ///
    /// `resolve` is used rather than a full `swift build` deliberately: it was
    /// verified to write `Package.resolved` for a source-control dependency
    /// (rc 0, file present afterwards) without compiling anything, so `init`
    /// does not have to pay a cold release build to learn this.
    ///
    /// WRITES. `resolve` creates `Package.resolved` and `.build/` in
    /// `directory`. Callers must either own that side effect (`init`, which
    /// commits the result before the freeze) or run this somewhere disposable
    /// (`baseline`, which probes the PINNED WORKTREE and resets it afterwards),
    /// never against a repository whose cleanliness a later gate depends on.
    public static func probe(in directory: URL, timeout: TimeInterval = 900) -> Requirement {
        let result: ProcessResult
        do {
            result = try Subprocess.run(swiftBinary, ["package", "resolve"],
                                        cwd: directory, env: nil, timeout: timeout)
        } catch {
            return .undetermined("swift package resolve could not run: \(error)")
        }
        guard result.exitCode == 0 else {
            return .undetermined(
                "swift package resolve exited \(result.exitCode): \(result.stderr.suffix(2000))")
        }
        return exists(in: directory) ? .required : .notProduced
    }

    // =====================================================================
    // MARK: - Git state
    // =====================================================================

    /// Whether `Package.resolved` is tracked by git at the current index.
    ///
    /// `nil` means the question could not be asked at all (not a git repository
    /// / git unavailable), which is different from a confident "no" and must not
    /// be collapsed into one.
    public static func isTracked(repo: URL) -> Bool? {
        let git = Git(repo: repo)
        guard (try? git.run(["rev-parse", "--git-dir"])) != nil else { return nil }
        return (try? git.run(["ls-files", "--error-unmatch", "--", name])) != nil
    }

    /// Whether `.gitignore` (or any other ignore file) would exclude
    /// `Package.resolved`. This is the state `doctor` used to actively
    /// RECOMMEND, and it is the reason that advice had to go: ignoring the
    /// lockfile leaves `packageResolvedSHA256` pinning nothing forever, silently
    /// un-pinning every dependency gate 2 exists to hold still.
    ///
    /// `git check-ignore` exits 0 when the path IS ignored, 1 when it is not,
    /// and 128 on error -- so a plain "did it succeed" test is exactly the right
    /// reading, but only after confirming this is a git repository at all.
    public static func isGitIgnored(repo: URL) -> Bool? {
        let git = Git(repo: repo)
        guard (try? git.run(["rev-parse", "--git-dir"])) != nil else { return nil }
        return (try? git.run(["check-ignore", "-q", "--", name])) != nil
    }
}
