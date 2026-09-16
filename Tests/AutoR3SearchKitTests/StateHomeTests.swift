import Testing
import Foundation
@testable import AutoR3SearchKit

@Test func differentReposGetDifferentStateDirectories() throws {
    let a = try StateHome(repo: URL(fileURLWithPath: "/tmp/repo-a"), env: [:])
    let b = try StateHome(repo: URL(fileURLWithPath: "/tmp/repo-b"), env: [:])
    #expect(a.root != b.root)
}

@Test func sameRepoIsStableAcrossCalls() throws {
    let a = try StateHome(repo: URL(fileURLWithPath: "/tmp/repo-a"), env: [:])
    let b = try StateHome(repo: URL(fileURLWithPath: "/tmp/repo-a"), env: [:])
    #expect(a.root == b.root)
}

@Test func stateLivesOutsideTheRepository() throws {
    let repo = URL(fileURLWithPath: "/tmp/some-repo")
    let home = try StateHome(repo: repo, env: [:])
    #expect(!home.root.path.hasPrefix(repo.path),
            "state inside the repo is state the agent can rewrite to make itself look good")
}

@Test func absoluteOverrideIsHonoured() throws {
    let home = try StateHome(repo: URL(fileURLWithPath: "/tmp/repo-a"),
                             env: ["AUTOR3SEARCH_SWIFT_STATE_HOME": "/tmp/custom-state"])
    #expect(home.root.path.hasPrefix("/tmp/custom-state"))
}

@Test func relativeOverrideIsRefused() {
    // A relative value resolves against whatever directory each command ran from,
    // so eval from a subdirectory and stop from the root would address different
    // state for the same run.
    #expect(throws: StateHomeError.self) {
        try StateHome(repo: URL(fileURLWithPath: "/tmp/repo-a"),
                      env: ["AUTOR3SEARCH_SWIFT_STATE_HOME": "relative/path"])
    }
}

@Test func baselineRecordRoundTrips() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("baseline.json")
    let record = BaselineRecord(tag: "sep16", frozenCommit: "aaa111", measurementCommit: "aaa111",
                                configSHA256: "c0", packageSwiftSHA256: "p0",
                                packageResolvedSHA256: "r0", toolVersion: "0.1.0")
    try record.save(to: url)
    #expect(try BaselineRecord.load(url) == record)
    try FileManager.default.removeItem(at: dir)
}

// Added beyond the brief: the brief's `stateLivesOutsideTheRepository` test only
// checks `home.root` itself. A future refactor could make a single accessor
// resolve back inside the repo (e.g. by joining against `repo` instead of
// `root`) without that test noticing. Since every piece of state the
// KEEP/DISCARD metric depends on is reached through these accessors, each one
// must independently be outside the repository.
@Test func everyAccessorLivesOutsideTheRepository() throws {
    let repo = URL(fileURLWithPath: "/tmp/some-other-repo")
    let home = try StateHome(repo: repo, env: [:])
    let tag = "sep16"
    let accessors: [(String, URL)] = [
        ("runDir", home.runDir(tag: tag)),
        ("baselineRecordURL", home.baselineRecordURL(tag: tag)),
        ("frozenDir", home.frozenDir(tag: tag)),
        ("worktreeURL", home.worktreeURL(tag: tag)),
        ("benchStorageURL", home.benchStorageURL(tag: tag)),
        ("runClaimURL", home.runClaimURL(tag: tag)),
        ("stopRequestURL", home.stopRequestURL(tag: tag)),
    ]
    for (name, url) in accessors {
        #expect(!url.path.hasPrefix(repo.path),
                "\(name) resolved inside the repository: \(url.path)")
    }
}
