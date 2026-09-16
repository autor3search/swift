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

@Test func conditionalTestGatingIsOkWhenCleanWarnsOnStrongHitsAndStaysInformationalOnBareEnvironmentReads() {
    // Clean: still names the blind spot no scan can catch.
    let clean = DoctorChecks.conditionalTestGating(strongHits: [], environmentReadCount: 0)
    #expect(clean.level == .ok)
    #expect(clean.detail.contains("blind spot"))
    #expect(clean.detail.contains("guard"))

    // A strong hit (`.enabled(if:`, `XCTSkip`, `ConditionTrait`, ...) is a real warning.
    let strong = DoctorChecks.conditionalTestGating(
        strongHits: ["Tests/Foo/BarTests.swift:12: @Test(.enabled(if: flag))"], environmentReadCount: 0)
    #expect(strong.level == .warn)
    #expect(strong.detail.contains("HEURISTIC"))
    #expect(strong.detail.contains("BarTests.swift:12"))
    #expect(strong.detail.contains("blind spot"))

    // A BARE environment read with no nearby skip construct is ordinary (CI
    // detection, feature flags) -- Finding 2 from the review requires this to
    // stay informational, not train people to ignore every real warning.
    let weak = DoctorChecks.conditionalTestGating(strongHits: [], environmentReadCount: 3)
    #expect(weak.level == .ok)
    #expect(weak.detail.contains("3"))
    #expect(weak.detail.contains("Ordinary"))
    #expect(weak.detail.contains("blind spot"))
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

// Finding 3 (review, fix round 1): `--skip-build` must actually skip the real
// build, reporting so as an `.ok` line, not silently doing it anyway.

@Test func skipBuildFlagReportsSkippedAndDoesNotBuild() throws {
    let (dir, _) = try makeGitFixture()
    defer { try? FileManager.default.removeItem(at: dir) }

    let findings = DoctorChecks.all(repo: dir, skipBuild: true)
    let build = findings.first { $0.title == "Benchmark build" }
    #expect(build?.level == .ok)
    #expect(build?.detail.contains("Skipped") == true)
    #expect(build?.detail.contains("--skip-build") == true)

    let productPath = dir.appendingPathComponent(".build/release/Bench").path
    #expect(!FileManager.default.fileExists(atPath: productPath), "--skip-build must not actually build")
}

// Finding 1 (review, fix round 1): a `ConditionTrait` defined in non-test
// source is exactly the evasion the heuristic previously missed -- the
// literal `.enabled(if:` marker never appears in the test file at all, only
// in a `Trait` extension living in optimizable code.

@Test func conditionTraitDefinedInSourceIsCaughtEvenThoughTheTestFileNeverMentionsIt() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Lib"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tests/LibTests"),
                                            withIntermediateDirectories: true)
    try """
        import Foundation
        import Testing

        public func f() -> Int { 1 }

        extension Trait {
            static var skipWhenSlow: ConditionTrait {
                .enabled(if: ProcessInfo.processInfo.environment["FAST"] == nil)
            }
        }
        """.write(to: dir.appendingPathComponent("Sources/Lib/Lib.swift"), atomically: true, encoding: .utf8)
    try """
        import Testing
        @testable import Lib

        @Test(.skipWhenSlow) func fReturnsOne() {
            #expect(f() == 1)
        }
        """.write(to: dir.appendingPathComponent("Tests/LibTests/LibTests.swift"),
                  atomically: true, encoding: .utf8)
    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "fixture",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        git init -q . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m one
        """], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0)

    let findings = DoctorChecks.all(repo: dir)
    let gating = findings.first { $0.title == "Conditionally-gated tests" }
    #expect(gating?.level == .warn)
    #expect(gating?.detail.contains("Lib.swift") == true, "the marker lives in Sources, not the test file")
    #expect(gating?.detail.contains("non-test source") == true)
}

// Finding (review, fix round 2): a marker mentioned only in a `///`/`//`
// comment must not produce a hit -- this exact pattern flagged
// `DoctorChecks.swift`'s own doc comments (17 hits against this repository,
// 15 of them this file's prose about the markers it scans for) before this
// fix. A marker inside a comment cannot disable a test, so filtering it
// loses no real signal, only noise. The same marker in real code must still
// be caught -- both bound in one fixture so the test would fail without the
// comment filter (comment-only hit leaking through) AND would fail if the
// filter over-reached and also ate real code (no hit at all).

@Test func commentOnlyMarkerProducesNoHitButTheSameMarkerInRealCodeStillDoes() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Lib"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tests/LibTests"),
                                            withIntermediateDirectories: true)
    // Comment-only mention of the marker: must NOT produce a hit.
    try """
        /// This file documents .enabled(if:) but never actually uses it.
        public func f() -> Int { 1 }
        """.write(to: dir.appendingPathComponent("Sources/Lib/Lib.swift"), atomically: true, encoding: .utf8)
    // The same marker, in real code: must still produce a hit.
    try """
        import Testing
        @testable import Lib

        @Test(.enabled(if: true)) func fReturnsOne() {
            #expect(f() == 1)
        }
        """.write(to: dir.appendingPathComponent("Tests/LibTests/LibTests.swift"),
                  atomically: true, encoding: .utf8)
    try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "fixture",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        git init -q . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m one
        """], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0)

    let findings = DoctorChecks.all(repo: dir)
    let gating = findings.first { $0.title == "Conditionally-gated tests" }
    #expect(gating?.level == .warn)
    #expect(gating?.detail.contains("Tests/LibTests/LibTests.swift") == true,
             "the real-code marker must still be caught")
    #expect(gating?.detail.contains("Sources/Lib/Lib.swift") == false,
             "a marker mentioned only in a comment must not be flagged")
}
