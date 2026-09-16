import Testing
import Foundation
@testable import AutoR3SearchKit

// The five tests below are verbatim from the task brief.

@Test func warnsWhenXCTestIsMissing() {
    // Verified real behaviour: CLT alone has no XCTest.framework, and swift test
    // fails with "unable to resolve module dependency: 'XCTest'".
    let f = DoctorChecks.xctestAvailability(developerDir: "/Library/Developer/CommandLineTools",
                                            hasXCTestFramework: false)
    #expect(f.level == .warn)
    #expect(f.detail.contains("Xcode"))
    #expect(f.detail.contains("XCTest"))
}

@Test func acceptsXCTestUnderXcode() {
    let f = DoctorChecks.xctestAvailability(developerDir: "/Applications/Xcode.app/Contents/Developer",
                                            hasXCTestFramework: true)
    #expect(f.level == .ok)
}

@Test func warnsOnLowPowerModeAndOnBattery() {
    #expect(DoctorChecks.lowPowerMode(true).level == .warn)
    #expect(DoctorChecks.lowPowerMode(false).level == .ok)
    #expect(DoctorChecks.power(onAC: false).level == .warn)
    #expect(DoctorChecks.power(onAC: true).level == .ok)
}

@Test func warnsOnLowDiskBecauseBuildDirectoriesAreLarge() {
    // The harness keeps a second build directory for the pinned worktree.
    #expect(DoctorChecks.diskSpace(freeBytes: 2_000_000_000).level == .warn)
    #expect(DoctorChecks.diskSpace(freeBytes: 200_000_000_000).level == .ok)
}

@Test func estimatesRunLengthFromCountAndBenchmarkCount() {
    let c = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "B",
                   benchmarks: ["A", "B"], count: 10, alpha: 0.05, minEffectPct: 1.0,
                   maxRegressPct: 5.0, timeoutSeconds: 600)
    // 2 benchmarks x 10 rounds x 2 sides = 40 process runs.
    let f = DoctorChecks.expectedRunLength(config: c, secondsPerRound: 0.05)
    #expect(f.detail.contains("40"))
}

// Additional coverage for the checks required beyond the brief's five, and
// for the pure judgements backing `all(repo:)`'s remaining probes. Same
// shape throughout: pure functions over injected facts.

@Test func xctestMissingMentionsTheFixIsInstallingXcode() {
    let f = DoctorChecks.xctestAvailability(developerDir: nil, hasXCTestFramework: false)
    #expect(f.level == .warn)
    #expect(f.detail.contains("install Xcode"))
}

@Test func coreCountsIsInformationalWhenKnown() {
    let f = DoctorChecks.coreCounts(performance: 4, efficiency: 6)
    #expect(f.level == .ok)
    #expect(f.detail.contains("4"))
    #expect(f.detail.contains("6"))
}

@Test func coreCountsWarnsWhenUnknown() {
    let f = DoctorChecks.coreCounts(performance: nil, efficiency: nil)
    #expect(f.level == .warn)
    #expect(f.detail.contains("Could not determine"))
}

@Test func competingLoadWarnsPastHalfCapacity() {
    #expect(DoctorChecks.competingLoad(loadAverage1m: 8.0, logicalCPUs: 10).level == .warn)
    #expect(DoctorChecks.competingLoad(loadAverage1m: 2.38, logicalCPUs: 10).level == .ok)
    #expect(DoctorChecks.competingLoad(loadAverage1m: nil, logicalCPUs: 10).level == .warn)
    #expect(DoctorChecks.competingLoad(loadAverage1m: 1.0, logicalCPUs: nil).level == .warn)
}

@Test func workingTreeReportsCleanDirtyAndUnknown() {
    #expect(DoctorChecks.workingTree(clean: true).level == .ok)
    let dirty = DoctorChecks.workingTree(clean: false)
    #expect(dirty.level == .warn)
    #expect(dirty.detail.contains("Package.resolved"))
    let unknown = DoctorChecks.workingTree(clean: nil)
    #expect(unknown.level == .warn)
    #expect(unknown.detail.contains("git"))
}

@Test func conditionalTestGatingIsOkWhenEmptyAndWarnsWithHits() {
    #expect(DoctorChecks.conditionalTestGating(hits: []).level == .ok)
    let f = DoctorChecks.conditionalTestGating(hits: ["Tests/Foo/BarTests.swift:12: @Test(.enabled(if: flag))"])
    #expect(f.level == .warn)
    #expect(f.detail.contains("heuristic".uppercased()) || f.detail.contains("HEURISTIC"))
    #expect(f.detail.contains("BarTests.swift:12"))
}

@Test func packageConfigurationNeverWarns() {
    // Running `doctor` before `init` is an ordinary, expected state, not a problem.
    #expect(DoctorChecks.packageConfiguration(configured: false).level == .ok)
    #expect(DoctorChecks.packageConfiguration(configured: true).level == .ok)
}

@Test func measurementBuildReflectsTheAttemptOutcome() {
    #expect(DoctorChecks.measurementBuild(succeeded: true, detail: "").level == .ok)
    let f = DoctorChecks.measurementBuild(succeeded: false, detail: "boom")
    #expect(f.level == .warn)
    #expect(f.detail.contains("BenchmarkTool"))
    #expect(f.detail.contains("boom"))
}

@Test func reportIsCalmOnAnAllOkMachineAndNamesEveryWarning() {
    let repo = URL(fileURLWithPath: "/tmp/repo")
    let allOk = [
        DoctorChecks.lowPowerMode(false),
        DoctorChecks.power(onAC: true),
    ]
    let okReport = DoctorChecks.report(findings: allOk, repo: repo)
    #expect(okReport.contains("All checks passed"))
    #expect(!okReport.contains("[WARN]"))

    let oneWarn = [
        DoctorChecks.lowPowerMode(true),
        DoctorChecks.power(onAC: true),
    ]
    let warnReport = DoctorChecks.report(findings: oneWarn, repo: repo)
    #expect(warnReport.contains("1 check(s) need attention"))
    #expect(warnReport.contains("[WARN]"))
    #expect(warnReport.contains("[OK]"))
}

// `all(repo:)` itself: exercised against a real, throwaway git fixture so the
// "never throws, always returns" contract and the repo-dependent checks
// (working tree, package describe, config) are bound against real probes
// rather than only the pure judgements above.

@Test func allNeverThrowsAndDegradesGracefullyOutsideAPackage() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Not a git repo, no Package.swift, no config: every repo-dependent
    // check must degrade instead of crashing the process.
    let findings = DoctorChecks.all(repo: dir)
    #expect(!findings.isEmpty)
    #expect(findings.contains { $0.title == "Working tree" && $0.level == .warn })
    #expect(findings.contains { $0.title == "Configuration" && $0.level == .ok })
}

@Test func allReportsCleanWorkingTreeAndConfigurationForARealFixture() throws {
    let (dir, git) = try makeGitFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let findings = DoctorChecks.all(repo: dir)
    #expect(findings.contains { $0.title == "Working tree" && $0.level == .ok })
    #expect(findings.contains { $0.title == "Configuration" && $0.level == .ok && $0.detail.contains("found") })
    #expect(findings.contains { $0.title == "Expected measurement length" })
    _ = try git.head() // fixture really is a usable git repo
}
