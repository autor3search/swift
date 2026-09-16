import Testing
import Foundation
@testable import AutoR3SearchKit

private func tempRepo() throws -> (URL, Git) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sh = URL(fileURLWithPath: "/bin/sh")
    let script = """
    git init -q .
    git config user.name  "Test"
    git config user.email "test@example.com"
    echo one > a.txt
    git add -A && git commit -q -m one
    """
    let r = try Subprocess.run(sh, ["-c", script], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "fixture repo setup failed: \(r.stderr)")
    return (dir, Git(repo: dir))
}

@Test func headReturnsTheCurrentCommit() throws {
    let (dir, git) = try tempRepo()
    let head = try git.head()
    #expect(head.count == 40)
    try FileManager.default.removeItem(at: dir)
}

@Test func detectsADirtyTree() throws {
    let (dir, git) = try tempRepo()
    #expect(try git.isClean() == true)
    try "two".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    #expect(try git.isClean() == false)
    try FileManager.default.removeItem(at: dir)
}

@Test func changedPathsListsFilesAgainstACommit() throws {
    let (dir, git) = try tempRepo()
    let base = try git.head()
    try "changed".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let sh = URL(fileURLWithPath: "/bin/sh")
    _ = try Subprocess.run(sh, ["-c", "git add -A && git commit -q -m two"],
                           cwd: dir, env: nil, timeout: 60)
    #expect(try git.changedPaths(since: base) == ["a.txt"])
    try FileManager.default.removeItem(at: dir)
}

@Test func worktreePinsAndRepointsAndVerifies() throws {
    let (dir, git) = try tempRepo()
    let first = try git.head()
    let wt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

    try Worktree.add(git: git, at: wt, commit: first)
    #expect(try Worktree.verify(at: wt, expectedCommit: first) == true)

    // A KEEP advances the measurement point to the newly kept commit.
    let sh = URL(fileURLWithPath: "/bin/sh")
    _ = try Subprocess.run(sh, ["-c", "echo two > a.txt && git add -A && git commit -q -m two"],
                           cwd: dir, env: nil, timeout: 60)
    let second = try git.head()
    try Worktree.repoint(git: git, at: wt, to: second)
    #expect(try Worktree.verify(at: wt, expectedCommit: second) == true)
    #expect(try Worktree.verify(at: wt, expectedCommit: first) == false)

    try Worktree.remove(git: git, at: wt)
    try FileManager.default.removeItem(at: dir)
}

// MARK: - Fixture cleanup and environment hygiene (fix round 1)
//
// The four frozen tests above clean up via a last statement, which a thrown
// `#expect` skips partway through — the mechanism behind the ~336 leaked
// fixture directories counted under `NSTemporaryDirectory()` during review.
// They must stay byte-identical to the brief, so that leak is accepted, not
// fixed, for those four specifically. Every test below uses
// `withTempDirectories` instead, so a thrown assertion can't leak a fixture.

/// Neutralizes the operator's global (`~/.gitconfig`) and system
/// (`/etc/gitconfig`) git config for every child process this test binary
/// spawns from here on. `Subprocess.run(..., env: nil)` resolves to
/// `ProcessInfo.processInfo.environment`, and `setenv` mutates exactly
/// that — so this reaches every `git` invocation any test in this file
/// makes, including the ones inside the four frozen tests' own `env: nil`
/// calls, without touching a single character of those tests' bodies.
///
/// This is defense-in-depth, not a hard guarantee for the four frozen tests
/// specifically: Swift does not run a non-`main.swift` file's top-level
/// `let` eagerly, and swift-testing does not guarantee execution order
/// across independent `@Test` functions, so in principle an unlucky
/// scheduler could run a frozen test's `git commit` before anything below
/// has referenced this value. In practice `withTempDirectories` references
/// it from the very first fixture any test in this file creates, and once
/// computed it stays set for the rest of the process. The fully
/// deterministic alternative, if this is ever observed to matter in CI, is
/// exporting `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null` in
/// the CI job's own environment before invoking `swift test`.
private let gitEnvironmentIsNeutralized: Bool = {
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    return true
}()

/// Removes `urls` when `body` returns OR throws, via `defer`. Shared by
/// every test added or modified in this fix round.
private func withTempDirectories<T>(_ urls: URL..., body: () throws -> T) rethrows -> T {
    _ = gitEnvironmentIsNeutralized
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
    return try body()
}

/// Like `tempRepo()`, but the initial commit also adds a `.gitignore`
/// covering `.build/` — needed by the `repoint` tests below to prove
/// `git clean -fd` (not `-fdx`) leaves ignored build output alone.
private func tempRepoWithGitignore() throws -> (URL, Git) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sh = URL(fileURLWithPath: "/bin/sh")
    let script = """
    git init -q .
    git config user.name  "Test"
    git config user.email "test@example.com"
    echo one > a.txt
    echo ".build/" > .gitignore
    git add -A && git commit -q -m one
    """
    let r = try Subprocess.run(sh, ["-c", script], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "fixture repo setup failed: \(r.stderr)")
    return (dir, Git(repo: dir))
}

/// Task 17's worktree-integrity gate depends on this: a worktree that is at
/// the right commit but has been locally modified must NOT verify as good.
/// `verify` folds the cleanliness check in (see the decision documented on
/// `Worktree.verify`), so dirty-but-correct-HEAD must read as false — a
/// single `verify` call is meant to be a fail-closed pass/fail gate on its
/// own, without every caller having to remember to additionally call
/// `isClean`.
@Test func verifyFailsWhenWorktreeIsDirtyEvenAtTheRightCommit() throws {
    let (dir, git) = try tempRepo()
    let wt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try withTempDirectories(dir, wt) {
        let commit = try git.head()
        try Worktree.add(git: git, at: wt, commit: commit)
        #expect(try Worktree.verify(at: wt, expectedCommit: commit) == true)

        // Modify a tracked file in place without committing: HEAD is still
        // `commit`, but the tree no longer matches it.
        try "tampered".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        #expect(try Worktree.isClean(at: wt) == false)
        #expect(try Worktree.verify(at: wt, expectedCommit: commit) == false)

        try Worktree.remove(git: git, at: wt)
    }
}

// MARK: - Finding 1: changedPaths must survive real third-party repositories

/// With default `core.quotePath`, plain `--name-only` returns non-ASCII
/// filenames as a quoted, octal-escaped literal (`"caf\303\251.swift"`) —
/// not a path Task 17's scope gate could ever match against the real
/// filesystem. `-z` disables that munging entirely and must return the real
/// path, regardless of the machine's `core.quotePath` setting.
@Test func changedPathsHandlesNonASCIIFilenames() throws {
    let (dir, git) = try tempRepo()
    try withTempDirectories(dir) {
        let base = try git.head()
        let name = "café.swift"
        try "content".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let sh = URL(fileURLWithPath: "/bin/sh")
        let r = try Subprocess.run(sh, ["-c", "git add -A && git commit -q -m two"],
                                   cwd: dir, env: nil, timeout: 60)
        #expect(r.exitCode == 0, "fixture commit failed: \(r.stderr)")
        #expect(try git.changedPaths(since: base) == [name])
    }
}

/// With default rename detection, a pure rename reports ONLY the new path —
/// the vacated old path is entirely absent, so a deletion would silently
/// disappear from the scope gate. `--no-renames` makes both sides explicit
/// and deterministic (rename-detection defaults are git-version and config
/// dependent).
@Test func changedPathsReportsBothSidesOfARename() throws {
    let (dir, git) = try tempRepo()
    try withTempDirectories(dir) {
        let base = try git.head()
        let sh = URL(fileURLWithPath: "/bin/sh")
        let r = try Subprocess.run(sh, ["-c", "git mv a.txt b.txt && git commit -q -m rename"],
                                   cwd: dir, env: nil, timeout: 60)
        #expect(r.exitCode == 0, "fixture rename failed: \(r.stderr)")
        #expect(try git.changedPaths(since: base) == ["a.txt", "b.txt"])
    }
}

// MARK: - Finding 2: repoint's postcondition must satisfy the new verify

/// `checkout --force` discards tracked modifications but leaves untracked
/// files behind. Since `verify` now also checks cleanliness, leftover
/// untracked residue from a previous run would make `verify` fail forever
/// even at the correct commit — `repoint` must clear it.
@Test func repointRemovesUntrackedResidueSoVerifyPasses() throws {
    let (dir, git) = try tempRepoWithGitignore()
    let wt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try withTempDirectories(dir, wt) {
        let commit = try git.head()
        try Worktree.add(git: git, at: wt, commit: commit)

        try "leftover".write(to: wt.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        #expect(try Worktree.verify(at: wt, expectedCommit: commit) == false,
                "sanity: untracked residue must make verify fail before repoint cleans it up")

        try Worktree.repoint(git: git, at: wt, to: commit)
        #expect(try Worktree.verify(at: wt, expectedCommit: commit) == true)
        #expect(FileManager.default.fileExists(atPath: wt.appendingPathComponent("untracked.txt").path) == false)

        try Worktree.remove(git: git, at: wt)
    }
}

/// The property protecting Task 16's warmed `.build` cache: `repoint` uses
/// `git clean -fd`, not `-fdx`, so files covered by `.gitignore` survive.
/// A future "tidy-up" that swaps in `-fdx` would silently destroy the warm
/// build cache and make every eval pay a cold Swift build — this test is
/// what would catch that regression.
@Test func repointPreservesIgnoredBuildOutput() throws {
    let (dir, git) = try tempRepoWithGitignore()
    let wt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try withTempDirectories(dir, wt) {
        let commit = try git.head()
        try Worktree.add(git: git, at: wt, commit: commit)

        let buildDir = wt.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let warmArtifact = buildDir.appendingPathComponent("warm-cache-marker")
        try "warm".write(to: warmArtifact, atomically: true, encoding: .utf8)

        try Worktree.repoint(git: git, at: wt, to: commit)
        #expect(FileManager.default.fileExists(atPath: warmArtifact.path) == true,
                "git clean -fd must not touch ignored paths — -fdx would destroy the warm .build cache")

        try Worktree.remove(git: git, at: wt)
    }
}

// MARK: - Finding 3: fileContents must round-trip non-UTF-8 bytes exactly

/// `Subprocess.run`'s `String(decoding:as:)` silently repairs invalid UTF-8
/// byte sequences to U+FFFD before `fileContents` would ever see them, and
/// `Data(result.stdout.utf8)` re-encodes the already-repaired string —
/// corrupting any blob that isn't valid UTF-8. `fileContents` must instead
/// use `Subprocess.runData` and return the real blob bytes.
@Test func fileContentsReturnsRawBytesNotUnicodeRepaired() throws {
    let (dir, git) = try tempRepo()
    try withTempDirectories(dir) {
        // "fo" + a lone UTF-8 continuation byte (invalid on its own) + "o".
        // A lossy decode-then-reencode would turn the single 0x80 byte into
        // the 3-byte U+FFFD replacement character, changing both the bytes
        // and the length.
        let rawBytes = Data([0x66, 0x6f, 0x80, 0x6f])
        try rawBytes.write(to: dir.appendingPathComponent("binary.dat"))
        let sh = URL(fileURLWithPath: "/bin/sh")
        let r = try Subprocess.run(sh, ["-c", "git add -A && git commit -q -m two"],
                                   cwd: dir, env: nil, timeout: 60)
        #expect(r.exitCode == 0, "fixture commit failed: \(r.stderr)")

        let commit = try git.head()
        let contents = try git.fileContents("binary.dat", at: commit)
        #expect(contents == rawBytes)
    }
}
