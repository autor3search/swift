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

/// Task 17's worktree-integrity gate depends on this: a worktree that is at
/// the right commit but has been locally modified must NOT verify as good.
/// `verify` folds the cleanliness check in (see the decision documented on
/// `Worktree.verify`), so dirty-but-correct-HEAD must read as false — a
/// single `verify` call is meant to be a fail-closed pass/fail gate on its
/// own, without every caller having to remember to additionally call
/// `isClean`.
@Test func verifyFailsWhenWorktreeIsDirtyEvenAtTheRightCommit() throws {
    let (dir, git) = try tempRepo()
    let commit = try git.head()
    let wt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

    try Worktree.add(git: git, at: wt, commit: commit)
    #expect(try Worktree.verify(at: wt, expectedCommit: commit) == true)

    // Modify a tracked file in place without committing: HEAD is still
    // `commit`, but the tree no longer matches it.
    try "tampered".write(to: wt.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

    #expect(try Worktree.isClean(at: wt) == false)
    #expect(try Worktree.verify(at: wt, expectedCommit: commit) == false)

    try Worktree.remove(git: git, at: wt)
    try FileManager.default.removeItem(at: dir)
}
