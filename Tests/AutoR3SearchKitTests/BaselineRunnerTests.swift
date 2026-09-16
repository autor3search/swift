import Testing
import Foundation
@testable import AutoR3SearchKit

@Test func refusesADirtyTree() throws {
    let (repo, _) = try makeGitFixture()
    try "dirty".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    #expect(throws: BaselineError.self) {
        try BaselineRunner.run(repo: repo, tag: "t1", env: isolatedStateEnv())
    }
    try FileManager.default.removeItem(at: repo)
}

@Test func refusesAReusedTag() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    _ = try BaselineRunner.run(repo: repo, tag: "t1", env: env)
    #expect(throws: BaselineError.self) { try BaselineRunner.run(repo: repo, tag: "t1", env: env) }
    try FileManager.default.removeItem(at: repo)
}

@Test func frozenAndMeasurementCommitsStartEqual() throws {
    let (repo, _) = try makeGitFixture()
    let r = try BaselineRunner.run(repo: repo, tag: "t1", env: isolatedStateEnv())
    #expect(r.frozenCommit == r.measurementCommit)
    try FileManager.default.removeItem(at: repo)
}

@Test func createsTheRunBranchWithTheFamilyNamingConvention() throws {
    let (repo, git) = try makeGitFixture()
    _ = try BaselineRunner.run(repo: repo, tag: "sep16", env: isolatedStateEnv())
    #expect(try git.currentBranch() == "autor3search-swift/sep16")
    try FileManager.default.removeItem(at: repo)
}

@Test func stateIsWrittenOutsideTheRepository() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    _ = try BaselineRunner.run(repo: repo, tag: "t1", env: env)
    let home = try StateHome(repo: repo, env: env)
    #expect(FileManager.default.fileExists(atPath: try home.baselineRecordURL(tag: "t1").path))
    #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".autor3search/baseline.json").path))
    try FileManager.default.removeItem(at: repo)
}

@Test func hashesTheManifestAndTheConfig() throws {
    let (repo, _) = try makeGitFixture()
    let r = try BaselineRunner.run(repo: repo, tag: "t1", env: isolatedStateEnv())
    #expect(r.packageSwiftSHA256.count == 64)
    #expect(r.configSHA256.count == 64)
    try FileManager.default.removeItem(at: repo)
}

// MARK: - Fix round 1, Fix 5 coverage

/// Removes `urls` when `body` returns OR throws, via `defer` -- matches the pattern
/// established in `GitTests.swift` for every test added after the six frozen ones, so a
/// failed `#expect`/`Issue.record` here can't leak a fixture directory.
private func withTempDirectories<T>(_ urls: URL..., body: () throws -> T) rethrows -> T {
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
    return try body()
}

/// Binds `BaselineError.staleRunBranch`: an existing run branch surviving from an
/// interrupted earlier attempt (no `baseline.json` ever written for that tag) must be
/// refused, not silently checked out and frozen at its own, now-stale, commit. Without
/// this guard, `frozenCommit`/`measurementCommit` would both record the WRONG commit
/// and `baseline` would report success -- the same silent-and-plausible failure class
/// as the baseline-advance bug this whole project exists to prevent, just at the
/// opposite end of a run instead of the middle of one.
@Test func refusesAStaleRunBranch() throws {
    let (repo, git) = try makeGitFixture()
    try withTempDirectories(repo) {
        let env = isolatedStateEnv()
        let staleCommit = try git.head()

        // Move HEAD forward with a second, real commit.
        try "two".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let sh = URL(fileURLWithPath: "/bin/sh")
        let r = try Subprocess.run(sh, ["-c", "git add -A && git commit -q -m two"],
                                   cwd: repo, env: nil, timeout: 60)
        #expect(r.exitCode == 0, "fixture commit failed: \(r.stderr)")
        let currentHead = try git.head()
        #expect(currentHead != staleCommit)

        // Simulate an earlier, interrupted attempt at this tag: the run branch was
        // created but baseline.json was never written (no BaselineRunner.run call
        // precedes this one for "stalebranch" -- the tagInUse guard cannot fire).
        try git.run(["branch", "autor3search-swift/stalebranch", staleCommit])

        do {
            _ = try BaselineRunner.run(repo: repo, tag: "stalebranch", env: env)
            Issue.record("expected BaselineError.staleRunBranch to be thrown")
        } catch let error as BaselineError {
            guard case .staleRunBranch(let tag, let branchCommit, let headCommit) = error else {
                Issue.record("expected .staleRunBranch, got \(error)")
                return
            }
            #expect(tag == "stalebranch")
            #expect(branchCommit == staleCommit)
            #expect(headCommit == currentHead)
        }
    }
}
