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
    // WAS `clean.detail.contains("guard")`, CHANGED DELIBERATELY. The old
    // blind-spot text named a `guard` at the top of a test body, and a
    // security review then defeated gate 6 with the test body untouched: the
    // real limit is that a frozen test constrains behaviour only as far as the
    // code it calls is honest. Asserting on "guard" would now pin the harness
    // to the wording that misdirected the reviewer, so it asserts on the
    // corrected claim instead. `guard` is still mentioned, in the full text
    // printed by `comparisonOperatorShadowing`.
    #expect(clean.detail.contains("HONEST"))

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

// =========================================================================
// MARK: - The dependency pin
// =========================================================================

/// THE SECOND-ORDER HOLE. `doctor`'s dirty-tree advice used to read "a common
/// innocent cause is an untracked Package.resolved; commit or .gitignore it".
/// Taking the `.gitignore` branch leaves `packageResolvedSHA256` pinning the
/// hash of zero bytes FOREVER, silently un-pinning every dependency -- so the
/// tool's own remedy quietly disabled the very check gate 2 exists to enforce.
/// The advice is not softened here, it is gone: `.gitignore` must not appear as
/// a suggested treatment for the lockfile anywhere in this finding.
@Test func dirtyTreeAdviceNeverSuggestsGitignoringTheLockfile() {
    let f = DoctorChecks.workingTree(clean: false)
    #expect(f.level == .warn)
    #expect(!f.detail.contains(".gitignore"),
            "doctor must never advise .gitignore as a remedy: \(f.detail)")
}

/// A dependency-free package legitimately has no lockfile and SwiftPM never
/// creates one. That must read as fine, not as a problem -- a `doctor` that
/// warned here would train people to ignore this check.
@Test func dependencyPinIsQuietForADependencyFreePackage() {
    let f = DoctorChecks.dependencyPin(externalDependencies: [], lockfileExists: false,
                                       lockfileTracked: nil, lockfileGitIgnored: false,
                                       recordedPins: [:])
    #expect(f.level == .ok)
}

/// Dependencies present, no lockfile: the exact state `baseline` now refuses,
/// reported before the operator hits that refusal.
@Test func dependencyPinWarnsWhenDependenciesHaveNoLockfile() {
    let f = DoctorChecks.dependencyPin(externalDependencies: ["benchmark"], lockfileExists: false,
                                       lockfileTracked: nil, lockfileGitIgnored: false,
                                       recordedPins: [:])
    #expect(f.level == .warn)
    #expect(f.detail.contains("Package.resolved"))
}

/// Lockfile on disk but NOT tracked -- either never committed, or committed
/// once and then ignored. `eval`'s build recreates it every run, so this is
/// permanent `dirty_working_tree` territory.
@Test func dependencyPinWarnsWhenTheLockfileIsUntracked() {
    let f = DoctorChecks.dependencyPin(externalDependencies: ["benchmark"], lockfileExists: true,
                                       lockfileTracked: false, lockfileGitIgnored: false,
                                       recordedPins: [:])
    #expect(f.level == .warn)
    #expect(f.detail.contains("git add"))
}

/// The harmful remedy, detected. A `.gitignore` entry for `Package.resolved` is
/// itself the alarm, whatever else looks healthy.
@Test func dependencyPinWarnsWhenTheLockfileIsGitignored() {
    let f = DoctorChecks.dependencyPin(externalDependencies: ["benchmark"], lockfileExists: true,
                                       lockfileTracked: true, lockfileGitIgnored: true,
                                       recordedPins: [:])
    #expect(f.level == .warn)
    #expect(f.detail.contains(".gitignore"))
}

/// MIGRATION. A repository baselined under the broken behaviour carries
/// `packageResolvedSHA256 == <sha256 of zero bytes>` -- a legitimate-looking
/// pin that pins nothing. `doctor` names it and names the tag; it does NOT
/// rewrite it, because silently "fixing" a recorded pin would mask a genuine
/// dependency change, which is precisely what the pin is for.
@Test func dependencyPinFlagsABaselineTakenUnderTheBrokenBehaviour() {
    let f = DoctorChecks.dependencyPin(externalDependencies: ["benchmark"], lockfileExists: true,
                                       lockfileTracked: true, lockfileGitIgnored: false,
                                       recordedPins: ["sep16": Lockfile.emptyDataSHA256])
    #expect(f.level == .warn)
    #expect(f.detail.contains("sep16"))
    #expect(f.detail.contains("baseline"), "the operator must be told to re-run baseline")
}

/// ROUND 2, MEDIUM 3. `doctor` creates the lockfile it complains about:
/// `measurementBuild` runs `swift build -c release`, which writes
/// `Package.resolved` into the package root. Observed live -- a second `doctor`
/// run on the same repository flipped this finding from "has no
/// Package.resolved" to "exists but is untracked", because doctor itself had
/// created it.
///
/// The finding is therefore keyed on TRACKEDNESS, which doctor's own build
/// cannot change. These are the two states doctor's build moves between, and
/// they must be indistinguishable in the report. This also covers the
/// `--skip-build` path, which writes nothing and so stays in the first state
/// forever: the two must not disagree about reality.
@Test func dependencyPinReportsTheSameThingBeforeAndAfterDoctorsOwnBuild() {
    let beforeBuild = DoctorChecks.dependencyPin(
        externalDependencies: ["benchmark"], lockfileExists: false,
        lockfileTracked: false, lockfileGitIgnored: false, recordedPins: [:])
    let afterBuild = DoctorChecks.dependencyPin(
        externalDependencies: ["benchmark"], lockfileExists: true,
        lockfileTracked: false, lockfileGitIgnored: false, recordedPins: [:])
    #expect(beforeBuild.level == .warn)
    #expect(beforeBuild == afterBuild, """
        doctor's own build must not change what doctor reports:
        before: \(beforeBuild.detail)
        after:  \(afterBuild.detail)
        """)
}

/// The transitive case, which the manifest signal cannot see: a package whose
/// only DIRECT dependency is a path dependency still gets a root
/// `Package.resolved` when that dependency's own manifest pulls a
/// source-control one (verified live). An empty `externalDependencies` list
/// with a lockfile on disk is that package, and it is still unpinned.
@Test func dependencyPinTreatsAnUntrackedLockfileAsEvidenceOfDependencies() {
    let f = DoctorChecks.dependencyPin(
        externalDependencies: [], lockfileExists: true,
        lockfileTracked: false, lockfileGitIgnored: false, recordedPins: [:])
    #expect(f.level == .warn)
    #expect(f.detail.contains("git add"))
}

/// Everything in order: dependencies, a tracked lockfile, and a real pin.
@Test func dependencyPinIsQuietWhenEverythingIsPinnedProperly() {
    let f = DoctorChecks.dependencyPin(
        externalDependencies: ["benchmark"], lockfileExists: true, lockfileTracked: true,
        lockfileGitIgnored: false,
        recordedPins: ["sep16": String(repeating: "a", count: 64)])
    #expect(f.level == .ok)
}

// =====================================================================
// MARK: - Forged comparisons
// =====================================================================

/// THE ATTACK, verbatim. A security review defeated gate 6 without disabling a
/// single test: the frozen tests ran, their assertions executed, and they
/// passed, because in-scope code gutted the function AND redeclared the
/// comparison the assertion uses. `eval` then reported `rc=0` on a change that
/// computes nothing.
///
/// The line below is the second half of that pair, exactly as it was written.
/// It must be classified as SHADOWING -- `[String: Int]` is already Equatable,
/// so this declaration is not a conformance, it is an override of one.
@Test func theForgedComparisonFromTheSecurityReviewIsClassifiedAsShadowing() {
    let forged = "public func == (lhs: [String: Int], rhs: [String: Int]) -> Bool { true }"
    let verdict = DoctorChecks.classifyOperatorDeclaration(forged)
    #expect(verdict?.isShadowing == true, "the exact declaration that defeated gate 6 was not flagged")
    #expect(verdict?.op == "==")
}

/// THE CRY-WOLF SIDE, which matters just as much: an ordinary hand-written
/// `Equatable` / `Comparable` conformance on the repository's own types must
/// NOT warn. `doctor`'s own stated policy is that a check firing on every
/// healthy repository trains people to stop reading all of them.
@Test func ordinaryEquatableAndComparableConformancesAreNotFlaggedAsShadowing() {
    let ordinary = [
        "    static func == (lhs: Self, rhs: Self) -> Bool {",
        "    public static func == (lhs: Token, rhs: Token) -> Bool {",
        "    static func < (lhs: Version, rhs: Version) -> Bool {",
        "public func == (lhs: [Row], rhs: [Row]) -> Bool {",
        "func == <T: Identifiable>(lhs: Boxed<T>, rhs: Boxed<T>) -> Bool {",
    ]
    for line in ordinary {
        let verdict = DoctorChecks.classifyOperatorDeclaration(line)
        #expect(verdict != nil, "not recognised as an operator declaration at all: \(line)")
        #expect(verdict?.isShadowing == false, "an ordinary conformance was flagged: \(line)")
    }

    // And nothing that is not an operator declaration may be classified as one.
    for line in [
        "    func compare<T>(_ a: T, _ b: T) -> Int {",
        "    let equal = a == b",
        "    if counts == expected { return }",
        "    func lessThan(_ a: Int, _ b: Int) -> Bool { a < b }",
        "myfunc == (lhs: Int, rhs: Int)",
    ] {
        #expect(DoctorChecks.classifyOperatorDeclaration(line) == nil,
                "a non-declaration was read as an operator declaration: \(line)")
    }
}

/// Every operator a frozen assertion can be routed through, on standard-library
/// operands. `~=` is the one worth having a test for: it is what `switch`/`case`
/// and a range assertion reduce to, and it is the least obvious member of the
/// set.
@Test func everyComparisonOperatorIsCoveredIncludingTheNonObviousOnes() {
    let cases: [(String, String)] = [
        ("func == (lhs: String, rhs: String) -> Bool { true }", "=="),
        ("func != (lhs: String, rhs: String) -> Bool { false }", "!="),
        ("func < (lhs: Int, rhs: Int) -> Bool { true }", "<"),
        ("func <= (lhs: Int, rhs: Int) -> Bool { true }", "<="),
        ("func > (lhs: Double, rhs: Double) -> Bool { false }", ">"),
        ("func >= (lhs: Double, rhs: Double) -> Bool { false }", ">="),
        ("func ~= (lhs: Range<Int>, rhs: Int) -> Bool { true }", "~="),
    ]
    for (line, expected) in cases {
        let verdict = DoctorChecks.classifyOperatorDeclaration(line)
        #expect(verdict?.op == expected, "wrong operator read from: \(line)")
        #expect(verdict?.isShadowing == true, "not flagged as shadowing: \(line)")
    }
    // Longest-match: `<=` must never be read as `<`, or the reported operator
    // would be a lie in the one place a human is being asked to look.
    #expect(DoctorChecks.classifyOperatorDeclaration("func <= (lhs: Int, rhs: Int) -> Bool {")?.op == "<=")
    #expect(DoctorChecks.classifyOperatorDeclaration("func >= (lhs: Int, rhs: Int) -> Bool {")?.op == ">=")
}

/// `[String: Int]` must yield `["String", "Int"]` and `[Row]` must yield
/// `["Row"]` -- the sugar is punctuation, the named types are the signal.
@Test func parameterTypeIdentifiersSeeThroughSugarAndDropParameterNames() {
    #expect(DoctorChecks.typeIdentifiers(inParameterList: "lhs: [String: Int], rhs: [String: Int]")
            == ["String", "Int", "String", "Int"])
    #expect(DoctorChecks.typeIdentifiers(inParameterList: "lhs: [Row], rhs: [Row]") == ["Row", "Row"])
    #expect(DoctorChecks.typeIdentifiers(inParameterList: "lhs: Self, rhs: Self") == ["Self", "Self"])
    #expect(DoctorChecks.typeIdentifiers(inParameterList: "_ lhs: String?, _ rhs: String?")
            == ["String", "String"])
}

/// The Finding itself: warn on shadowing, inform (never warn) on ordinary
/// conformances, and name the REAL blind spot in both branches.
@Test func comparisonOperatorFindingWarnsOnShadowingAndOnlyInformsOnOrdinaryConformances() {
    let clean = DoctorChecks.comparisonOperatorShadowing(shadowingHits: [], ordinaryOperatorCount: 0)
    #expect(clean.level == .ok)

    // Twelve ordinary Equatable conformances is a NORMAL repository. If this
    // ever becomes `.warn`, the check has started crying wolf and will be
    // ignored on the day it matters.
    let ordinary = DoctorChecks.comparisonOperatorShadowing(
        shadowingHits: [], ordinaryOperatorCount: 12)
    #expect(ordinary.level == .ok, "an ordinary Equatable conformance must never raise a warning")
    #expect(ordinary.detail.contains("12"))

    let shadowing = DoctorChecks.comparisonOperatorShadowing(
        shadowingHits: ["Sources/Demo/Demo.swift:9: public func == (lhs: [String: Int], rhs: [String: Int]) -> Bool { true }"],
        ordinaryOperatorCount: 0)
    #expect(shadowing.level == .warn)
    #expect(shadowing.detail.contains("Demo.swift:9"))
    #expect(shadowing.detail.contains("overload resolution"))
}

/// THE CORRECTED BLIND-SPOT TEXT. The wording this replaces told a reviewer to
/// "review tests with non-trivial early setup by hand" -- pointing at the test
/// body, which in the demonstrated attack was UNTOUCHED. Every branch that
/// prints a blind spot must now name the real class instead.
@Test func theBlindSpotTextNamesGuttedCodeAndForgedComparisonsNotTheTestBody() {
    let branches = [
        DoctorChecks.conditionalTestGating(strongHits: [], environmentReadCount: 0),
        DoctorChecks.conditionalTestGating(strongHits: [], environmentReadCount: 4),
        DoctorChecks.conditionalTestGating(strongHits: ["Tests/T.swift:1: XCTSkip()"],
                                           environmentReadCount: 0),
        DoctorChecks.comparisonOperatorShadowing(shadowingHits: [], ordinaryOperatorCount: 0),
        DoctorChecks.comparisonOperatorShadowing(
            shadowingHits: ["Sources/Demo/Demo.swift:9: func == (lhs: Int, rhs: Int) -> Bool { true }"],
            ordinaryOperatorCount: 0),
    ]
    for f in branches {
        #expect(f.detail.contains("HONEST"),
                "a blind-spot branch no longer states the real limit of a frozen test: \(f.title)")
        #expect(f.detail.contains("forge"),
                "a blind-spot branch does not name the forged comparison: \(f.title)")
        #expect(!f.detail.contains("review tests with non-trivial early setup by hand"),
                "the misdirecting wording came back in: \(f.title)")
    }
}

/// A CHARACTERIZATION TEST: it asserts what the check does NOT catch.
///
/// A reviewer wrote two evasions that compile and land silently in the
/// "ordinary" tier. Neither is fixed -- `doctor` is advisory and always exits
/// 0, so the cost of the gap is a missing hint, while the cost of chasing it
/// with more regex is a check that warns on healthy code and is then ignored
/// on the day it matters. What is NOT acceptable is the gap being invisible,
/// so it is written down here, in the suite, where someone tightening this
/// check will trip over it.
///
/// **If you make either of these flag, DELETE the corresponding expectation
/// below and the paragraph it mirrors in `DoctorChecks.operatorScanIsEvadable`
/// and in the README.** A failing test here is good news; a stale claim of
/// coverage is not.
@Test func knownEvasionsOfTheOperatorScanAreStillEvasions() {
    // EVASION 1 -- parameter list on the next line. `classifyOperatorDeclaration`
    // reports the operator but cannot read the operands, and deliberately
    // returns `isShadowing: false` rather than guess.
    let splitLine = DoctorChecks.classifyOperatorDeclaration("public func !=")
    #expect(splitLine?.op == "!=", "the declaration is still recognised as one")
    #expect(splitLine?.isShadowing == false,
            "a signature whose operands could not be read must not be guessed at")

    // EVASION 2 -- the operand type behind a typealias. Resolving `Counts` to
    // `[String: Int]` needs type resolution, i.e. a compiler.
    let aliased = DoctorChecks.classifyOperatorDeclaration(
        "public func ~= (lhs: Counts, rhs: Counts) -> Bool { true }")
    #expect(aliased?.op == "~=")
    #expect(aliased?.isShadowing == false,
            "a text scan cannot see through a typealias, and this records that")

    // The canonical spelling of the same forgery IS caught -- so the gap is in
    // the spelling, not in the idea.
    #expect(DoctorChecks.classifyOperatorDeclaration(
        "public func ~= (lhs: [String: Int], rhs: [String: Int]) -> Bool { true }")?
        .isShadowing == true)
}

/// Both branches -- including the ALL-CLEAR one -- must say the check is
/// evadable. A clean result from an evadable check that does not say so reads
/// as "there is nothing here", and that is the reading that gets someone hurt.
@Test func bothBranchesStateThatTheOperatorScanCanBeEvaded() {
    for f in [
        DoctorChecks.comparisonOperatorShadowing(shadowingHits: [], ordinaryOperatorCount: 0),
        DoctorChecks.comparisonOperatorShadowing(shadowingHits: [], ordinaryOperatorCount: 9),
        DoctorChecks.comparisonOperatorShadowing(
            shadowingHits: ["Sources/D/D.swift:1: func == (lhs: Int, rhs: Int) -> Bool { true }"],
            ordinaryOperatorCount: 0),
    ] {
        #expect(f.detail.contains("EVADE IT"),
                "a branch of the operator check implies coverage it does not have")
        #expect(f.detail.contains("typealias"))
        #expect(f.detail.contains("NEXT line"))
    }
}
