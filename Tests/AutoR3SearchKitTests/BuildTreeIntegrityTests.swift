import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/BuildTreeIntegrityTests.swift
//
// THE SAME ROOT CAUSE, A THIRD TIME: the gates hash something the compiler does
// not read, and do not hash something it does.
//
// Round 1 and 2 closed the paths git could be talked out of reporting. These
// two close the last places where nothing was hashed at all:
//
//   - `.build/checkouts/**` -- dependency SOURCE, inside the repository under
//     test, exempt from the out-of-scope inventory and from the dirty-tree gate
//     because `.build/` is excluded from both, collapsed by git to one `!!`
//     record, compiled by SwiftPM, never re-verified by it, and holding
//     build-tool PLUGINS that the build EXECUTES.
//   - the pinned measurement worktree, whose integrity gate asks `git status`.
//
// Every test asserts THE PREMISE first.

/// Counts every sample. The assertion is `== 0` wherever the gate refuses.
private final class ZeroCallSource2: MetricSource, @unchecked Sendable {
    var calls = 0
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        calls += 1
        return 100.0
    }
}

private func shell(_ script: String, in dir: URL) throws {
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script],
                               cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "\(script): \(r.stderr)")
}

/// Plants a stand-in dependency checkout: a source file and a plugin file under
/// `.build/checkouts/<name>/`, the layout SwiftPM creates and compiles from.
/// `.build` is gitignored by the fixture, so none of this is visible to git.
private func plantCheckout(_ repo: URL, name: String, body: String) throws {
    let dir = repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/\(name)/Sources/\(name)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try body.write(to: dir.appendingPathComponent("\(name).swift"), atomically: true, encoding: .utf8)
    let plugins = repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/\(name)/Plugins/BenchmarkPlugin")
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    try "// a build-tool plugin: SwiftPM EXECUTES this during the build\n".write(
        to: plugins.appendingPathComponent("plugin.swift"), atomically: true, encoding: .utf8)
    // Each real checkout is a git repository; its own .git must not be hashed.
    let dotGit = repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/\(name)/.git")
    try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
    try "ref: refs/heads/main\n".write(to: dotGit.appendingPathComponent("HEAD"),
                                       atomically: true, encoding: .utf8)
}

// =========================================================================
// MARK: - The dependency checkouts
// =========================================================================

/// Editing a dependency's source wins a measurement from a comment-only
/// commit. Measured end to end against the real binary before this gate
/// existed, on `Fixtures/DemoPackage`, with one `sed` into
/// `.build/checkouts/benchmark/Sources/Benchmark/BenchmarkExecutor.swift`
/// (`add(Int(nanoSeconds))` -> `add(Int(nanoSeconds) / 100)`) and a commit
/// whose entire diff was `+// no-op comment`:
/// `rc 0, verdict keep, ratio 0.009923, warnings []`.
@Test func aTamperedDependencyCheckoutIsRefusedAndNeverMeasured() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    try plantCheckout(repo, name: "benchmark", body: "public let timerScale = 1\n")
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let key = "benchmark/Sources/benchmark/benchmark.swift"
    #expect(record.checkoutSHA256?[key] != nil,
            "baseline must inventory the dependency source: \(record.checkoutSHA256 ?? [:])")
    #expect(record.checkoutSHA256?["benchmark/Plugins/BenchmarkPlugin/plugin.swift"] != nil,
            "the build-tool plugin is the arbitrary-code-execution surface and must be covered")
    #expect(record.checkoutSHA256?.keys.contains { $0.hasPrefix("benchmark/.git/") } == false,
            "a checkout's own .git is not compiled and must not be hashed")

    // THE PREMISE: git is blind to all of it. `.build/` is gitignored, so it
    // collapses to one ignored record and the dirty-tree gate allowlists it.
    try "public let timerScale = 100\n".write(
        to: repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/benchmark/Sources/benchmark/benchmark.swift"),
        atomically: true, encoding: .utf8)
    try makeInScopeCommit(repo, "innocent looking")
    #expect(try git.isClean(), "the premise: gate 2b sees a clean tree")
    let ignored = try git.status(includingIgnored: true).filter { $0.isIgnored }
    #expect(ignored.allSatisfy { BaselineRunner.isHarnessOutput($0.path) },
            "the premise: everything ignored here is allowlisted harness output -- \(ignored)")
    #expect(EvalRunner.treeInventoryFailure(repo: repo, record: record, scope: ["Sources/**"]) == nil,
            "the premise: the out-of-scope inventory never walks .build/")

    let source = ZeroCallSource2()
    let v = try EvalRunner.run(repo: repo, env: env, source: source, now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "dependency_checkout_modified", "got \(v.reason ?? "nil")")
    #expect(v.warnings.first?.contains(key) == true,
            "the refusal must NAME the offending path: \(v.warnings)")
    #expect(source.calls == 0, "nothing may be measured: \(source.calls) samples taken")
}

/// A file ADDED inside a present checkout counts: SwiftPM globs a target's
/// source directory, so a new file there is compiled with no manifest edit.
@Test func aFilePlantedInsideAPresentDependencyCheckoutIsRefused() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    try plantCheckout(repo, name: "benchmark", body: "public let timerScale = 1\n")
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    try "public let sneaky = 1\n".write(
        to: repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/benchmark/Sources/benchmark/Extra.swift"),
        atomically: true, encoding: .utf8)
    let failure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: try StateHome(repo: repo, env: env).worktreeURL(tag: "t"),
        record: record)
    #expect(failure?.reason == "dependency_checkout_modified")
    #expect(failure?.detail.contains("added:    benchmark/Sources/benchmark/Extra.swift") == true,
            "\(failure?.detail ?? "nil")")
}

/// ...and a file REMOVED from one, for the same reason in reverse.
@Test func aFileDeletedFromAPresentDependencyCheckoutIsRefused() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    try plantCheckout(repo, name: "benchmark", body: "public let timerScale = 1\n")
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    try FileManager.default.removeItem(
        at: repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/benchmark/Plugins/BenchmarkPlugin/plugin.swift"))
    let failure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: try StateHome(repo: repo, env: env).worktreeURL(tag: "t"),
        record: record)
    #expect(failure?.detail.contains("removed:  benchmark/Plugins/BenchmarkPlugin/plugin.swift") == true,
            "\(failure?.detail ?? "nil")")
}

/// THE OTHER DIRECTION, and the reason the rule is per-dependency rather than
/// per-file: a WHOLE missing checkout must stay legal. `rm -rf .build` is an
/// ordinary thing for an agent or an operator to do, and SwiftPM re-clones the
/// dependency at the revision `Package.resolved` pins -- a file whose own bytes
/// gate 2a hashes. Refusing here would brick the run on a clean build.
@Test func aWholeMissingDependencyCheckoutIsAllowedBecauseSwiftPMRestoresIt() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    try plantCheckout(repo, name: "benchmark", body: "public let timerScale = 1\n")
    try plantCheckout(repo, name: "swift-atomics", body: "public let atomics = 1\n")
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let worktree = try StateHome(repo: repo, env: env).worktreeURL(tag: "t")
    #expect(EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record) == nil)

    // One dependency deleted entirely: fine.
    try FileManager.default.removeItem(
        at: repo.appendingPathComponent("\(BaselineRunner.checkoutsSubpath)/swift-atomics"))
    #expect(EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record) == nil,
            "a whole missing checkout is re-cloned from the pin, not tampering")

    // The entire checkouts tree deleted: also fine.
    try FileManager.default.removeItem(
        at: repo.appendingPathComponent(BaselineRunner.checkoutsSubpath))
    #expect(EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record) == nil,
            "`rm -rf .build` must stay a legal thing to do")
}

/// Checkouts appearing where baseline recorded none cannot be verified against
/// anything, so they are refused rather than compiled on trust -- that tree
/// contains plugins the build executes.
@Test func checkoutsAppearingWhereBaselineRecordedNoneAreRefused() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(record.checkoutSHA256?.isEmpty == true,
            "a dependency-free fixture records an empty checkout inventory")

    try plantCheckout(repo, name: "benchmark", body: "public let timerScale = 1\n")
    let failure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: try StateHome(repo: repo, env: env).worktreeURL(tag: "t"),
        record: record)
    #expect(failure?.reason == "dependency_checkout_modified")
    #expect(failure?.detail.contains("baseline recorded none") == true,
            "\(failure?.detail ?? "nil")")
}

/// A record from before the inventory existed is refused, not waved through,
/// under the reason string the other two inventories already use.
@Test func aBaselineWithNoCheckoutInventoryIsRefused() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    var record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    record.checkoutSHA256 = nil
    let failure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: try StateHome(repo: repo, env: env).worktreeURL(tag: "t"),
        record: record)
    #expect(failure?.reason == "baseline_predates_tree_inventory")
}

// =========================================================================
// MARK: - The pinned measurement worktree
// =========================================================================

/// `Worktree.verify` asks `git status`, and the agent can reach this worktree
/// with a shell. Measured end to end before the restore existed, with the
/// baseline worktree's benchmark helper set from 1750 to 17500 behind
/// `--assume-unchanged` and a comment-only commit: `rc 0, keep, ratio 0.10006`
/// -- the BASELINE was made ten times slower, so doing nothing looked like a
/// tenfold win.
@Test func theWorktreeIsRestoredFromIndexFlagTamperingBeforeMeasuring() throws {
    for flag in ["--assume-unchanged", "--skip-worktree"] {
        let (repo, git) = try makeGitFixture()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
        let worktree = try StateHome(repo: repo, env: env).worktreeURL(tag: "t")
        let helper = worktree.appendingPathComponent("Sources/Lib/Lib.swift")
        let original = try String(contentsOf: helper, encoding: .utf8)

        try shell("git update-index \(flag) Sources/Lib/Lib.swift", in: worktree)
        try "public func f() -> Int { 99 } // tampered\n".write(
            to: helper, atomically: true, encoding: .utf8)

        // THE PREMISE: the gate that guards this worktree is blind.
        #expect(try Worktree.verify(at: worktree, expectedCommit: record.measurementCommit),
                "\(flag): verify must be fooled, or this test proves nothing")
        #expect(try String(contentsOf: helper, encoding: .utf8) != original)

        let flagged = try Worktree.restoreToPin(
            git: git, at: worktree, to: record.measurementCommit)
        #expect(flagged.count == 1, "\(flag): the flagged path must be reported: \(flagged)")
        #expect(flagged.first?.path == "Sources/Lib/Lib.swift")
        #expect(try String(contentsOf: helper, encoding: .utf8) == original,
                "\(flag): the worktree must be restored before anything is measured")
        #expect(try Worktree.indexFlaggedPaths(at: worktree).isEmpty,
                "\(flag): the index flag must be cleared, or the next eval is fooled again")
    }
}

/// THE MEASURED GIT BEHAVIOUR THE RESTORE DEPENDS ON, pinned here because it is
/// surprising and because getting it wrong is silent.
///
/// 1. `git checkout --force` restores a file hidden with `--assume-unchanged`
///    but NOT one hidden with `--skip-worktree`. A restore built on the forced
///    checkout alone therefore leaves the tampered content in place.
/// 2. Passing `--no-assume-unchanged` and `--no-skip-worktree` to ONE
///    `git update-index` invocation exits 0 and does NOTHING. Each alone works.
///    The first version of `restoreToPin` combined them, reported "the flags
///    were cleared" in a warning, and let the attack through with
///    `rc 0, keep, ratio 0.10000570`.
@Test func skipWorktreeSurvivesAForcedCheckoutAndNeedsItsOwnUpdateIndexCall() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try shell("""
        git init -q . && git config user.name T && git config user.email t@e.com
        printf 'original\\n' > f.txt && git add -A && git commit -q -m one
        """, in: dir)
    let file = dir.appendingPathComponent("f.txt")

    // (1) skip-worktree survives a forced checkout.
    try shell("git update-index --skip-worktree f.txt", in: dir)
    try "TAMPERED\n".write(to: file, atomically: true, encoding: .utf8)
    try shell("git checkout --force HEAD", in: dir)
    #expect(try String(contentsOf: file, encoding: .utf8) == "TAMPERED\n",
            "if git ever fixes this, restoreToPin can be simplified -- until then it cannot")

    // (2) the two flags in one invocation succeed and change nothing.
    try shell("git update-index --no-assume-unchanged --no-skip-worktree -- f.txt", in: dir)
    #expect(try Worktree.indexFlaggedPaths(at: dir).count == 1,
            "combining the flags is a silent no-op; that is why restoreToPin issues two calls")

    // ...and separately, they work.
    try shell("git update-index --no-skip-worktree -- f.txt", in: dir)
    #expect(try Worktree.indexFlaggedPaths(at: dir).isEmpty)
    try shell("git checkout --force HEAD", in: dir)
    #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
}

/// `restoreToPin` must not report success it did not achieve. Its
/// post-condition is checked, not assumed -- the first version's warning
/// claimed the flags were cleared while the attack was still succeeding.
@Test func restoreToPinReportsNothingFlaggedOnAnUntouchedWorktree() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let worktree = try StateHome(repo: repo, env: env).worktreeURL(tag: "t")

    let flagged = try Worktree.restoreToPin(git: git, at: worktree, to: record.measurementCommit)
    #expect(flagged.isEmpty, "a clean worktree has nothing to report")
    #expect(try Worktree.verify(at: worktree, expectedCommit: record.measurementCommit))

    // Idempotent: it runs before every measurement, so running it twice must
    // leave the worktree exactly as sound as running it once.
    _ = try Worktree.restoreToPin(git: git, at: worktree, to: record.measurementCommit)
    #expect(try Worktree.verify(at: worktree, expectedCommit: record.measurementCommit))
}
