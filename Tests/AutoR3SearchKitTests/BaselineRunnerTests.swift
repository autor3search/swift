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
