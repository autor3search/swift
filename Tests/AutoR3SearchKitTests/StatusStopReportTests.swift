import Testing
import Foundation
@testable import AutoR3SearchKit

private func row(_ n: Int, _ status: String, _ score: Double, unsafe: Int = 0) -> ResultsRow {
    ResultsRow(experiment: n, commit: "c\(n)", status: status, score: score,
               reason: "", unsafeCount: unsafe, toolVersion: "0.1.0", timestamp: "t")
}

@Test func cumulativeSpeedupIsTheProductOfKeptScores() {
    // Each kept score is only that experiment's incremental contribution, because
    // the measurement baseline advanced. So successive wins compound.
    let s = ReportRunner.summarize([row(1, "keep", 0.5), row(2, "discard", 0.99), row(3, "keep", 0.5)])
    #expect(abs(s.cumulativeSpeedup - 0.25) < 1e-12)
}

@Test func countsByStatus() {
    let s = ReportRunner.summarize([row(1, "keep", 0.5), row(2, "discard", 1.0),
                                    row(3, "fail", 0), row(4, "crash", 0)])
    #expect(s.counts["keep"] == 1)
    #expect(s.counts["discard"] == 1)
    #expect(s.counts["fail"] == 1)
    #expect(s.counts["crash"] == 1)
}

@Test func reportNamesKeptCommitsThatIntroducedUnsafe() {
    let s = ReportRunner.summarize([row(1, "keep", 0.9), row(2, "keep", 0.8, unsafe: 2),
                                    row(3, "discard", 1.0, unsafe: 5)])
    #expect(s.unsafeCommits == [2], "only KEPT commits matter: discarded ones were reset away")
}

@Test func stopRequestIsWrittenClearedAndDetected() throws {
    let env = isolatedStateEnv()
    let home = try StateHome(repo: URL(fileURLWithPath: "/tmp/r"), env: env)
    #expect(StopRequest.isPending(home: home, tag: "t") == false)
    try StopRequest.request(home: home, tag: "t")
    #expect(StopRequest.isPending(home: home, tag: "t") == true)
    try StopRequest.clear(home: home, tag: "t")
    #expect(StopRequest.isPending(home: home, tag: "t") == false)
}

@Test func statusNeverWritesAnything() throws {
    // Checking on a run must not be able to change it.
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)
    let before = try FileManager.default.contentsOfDirectory(atPath: try home.runDir(tag: "t").path).sorted()
    _ = try StatusRunner.describe(repo: repo, tag: "t", env: env)
    let after = try FileManager.default.contentsOfDirectory(atPath: try home.runDir(tag: "t").path).sorted()
    #expect(before == after)
}
