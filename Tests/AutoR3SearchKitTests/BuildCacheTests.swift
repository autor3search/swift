import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/BuildCacheTests.swift
//
// THE ONE PART OF `.build/` NO INVENTORY CAN COVER.
//
// Gate 2d hashes `.build/checkouts`, where a build-tool plugin's SOURCE lives.
// SwiftPM compiles that source once and caches the RESULT in `.build/plugins`,
// and llbuild decides whether to recompile from recorded input signatures -- so
// a tampered plugin binary whose sources have not changed is REUSED, and it is
// EXECUTED during the build, after every integrity gate has passed. The same
// shape applies to `.build/out`: a poisoned object file for a module whose
// sources did not change is linked into the measured binary.
//
// A hash cannot fix this, because the artifact is legitimately rewritten by
// every build. Absence can. The plugins are deleted unconditionally (measured
// ~0.81 s per side); the whole output tree is deleted only on request (~18 s
// per side, which roughly doubles an experiment).

private final class ZeroCallSource3: MetricSource, @unchecked Sendable {
    var calls = 0
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        calls += 1
        return 100.0
    }
}

/// Plants the shapes SwiftPM really creates: an executable plugin binary and
/// its state file under `.build/plugins/cache`, plugin-GENERATED Swift under
/// `.build/plugins/outputs`, and compiled output under `.build/out`.
@discardableResult
private func plantBuildCache(_ directory: URL) throws -> [URL] {
    var planted: [URL] = []
    for (subpath, body) in [
        (".build/plugins/cache/BenchmarkPlugin", "a Mach-O executable SwiftPM runs at build time"),
        (".build/plugins/cache/BenchmarkPlugin-state.json", "{}"),
        (".build/plugins/outputs/repo/Bench/generated.swift", "// plugin-generated, compiled in"),
        (".build/out/Objects/Demo.o", "a compiled object llbuild may reuse"),
        (".build/release/Bench", "a linked binary"),
    ] {
        let url = directory.appendingPathComponent(subpath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        planted.append(url)
    }
    // Resolved dependency state, which must SURVIVE both purges: re-creating it
    // would need the network, and gate 2d has already verified it.
    let checkout = directory.appendingPathComponent(
        "\(BaselineRunner.checkoutsSubpath)/benchmark/Sources/benchmark/benchmark.swift")
    try FileManager.default.createDirectory(
        at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "public let x = 1\n".write(to: checkout, atomically: true, encoding: .utf8)
    return planted
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// The plugin cache is deleted from BOTH sides on every eval, and the resolved
/// dependency state is not -- so this is a plugin recompile, never a re-resolve
/// and never a network call.
@Test func thePluginCacheIsPurgedFromBothSidesBeforeAnythingIsBuilt() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    // The checkout is planted BEFORE baseline so gate 2d records and accepts
    // it; otherwise this test would stop at `dependency_checkout_modified` and
    // never reach the purge it exists to bind. (Observed: it did exactly that
    // on the first attempt -- which is itself gate 2d working.)
    try plantBuildCache(repo)
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let worktree = try StateHome(repo: repo, env: env).worktreeURL(tag: "t")
    // Same bytes on the worktree side, which is what a real resolve produces:
    // measured on the demo package, the two checkouts are byte-identical.
    try plantBuildCache(worktree)

    for side in [repo, worktree] {
        #expect(exists(side.appendingPathComponent(EvalRunner.pluginCacheSubpath)),
                "the premise: a compiled plugin is present before the eval")
    }

    try makeInScopeCommit(repo, "an ordinary experiment")
    _ = try EvalRunner.run(repo: repo, env: env, source: ZeroCallSource3(), now: Date.init)

    for (side, label) in [(repo, "candidate"), (worktree, "worktree")] {
        #expect(!exists(side.appendingPathComponent(EvalRunner.pluginCacheSubpath)),
                "\(label): the compiled plugin cache must not survive into the build")
        // ...and the resolved dependency state DID survive.
        #expect(exists(side.appendingPathComponent(
            "\(BaselineRunner.checkoutsSubpath)/benchmark/Sources/benchmark/benchmark.swift")),
                "\(label): checkouts must survive -- re-creating them would need the network")
    }
}

/// The build-output purge is OFF by default: compiled objects survive, so an
/// ordinary experiment still pays an incremental build rather than a cold one.
@Test func theBuildOutputPurgeIsOffByDefault() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try plantBuildCache(directory)

    #expect(EvalRunner.purgeBuildOutputRequested(env: [:]) == false)
    #expect(EvalRunner.purgePluginCache(in: directory, where: "a fixture") == nil)

    #expect(!exists(directory.appendingPathComponent(".build/plugins")),
            "the plugins go unconditionally")
    #expect(exists(directory.appendingPathComponent(".build/out/Objects/Demo.o")),
            "compiled objects stay: deleting them doubles the cost of every experiment")
    #expect(exists(directory.appendingPathComponent(".build/release/Bench")))
}

/// ...and ON when asked, which deletes every compiled artifact while leaving
/// the resolved dependency state alone -- a cold BUILD, not a re-resolve.
@Test func theBuildOutputPurgeRemovesEveryCompiledArtifactWhenRequested() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try plantBuildCache(directory)

    #expect(EvalRunner.purgeBuildOutputRequested(
        env: [EvalRunner.purgeBuildOutputEnvKey: "1"]))
    #expect(EvalRunner.purge(
        EvalRunner.buildOutputSubpaths, in: directory, reason: "build_output_not_purged",
        what: "the compiled build output", where: "a fixture") == nil)

    for subpath in EvalRunner.buildOutputSubpaths {
        #expect(!exists(directory.appendingPathComponent(subpath)), "\(subpath) must be gone")
    }
    #expect(exists(directory.appendingPathComponent(
        "\(BaselineRunner.checkoutsSubpath)/benchmark/Sources/benchmark/benchmark.swift")),
            "checkouts survive: this is a cold build, not a re-resolve -- no network needed")
}

/// THE OVERRIDE CAN ONLY TIGHTEN, and that is the whole reason it is safe to
/// read from the environment. In many deployments the agent under measurement
/// is the process that invokes `eval`, so an environment variable that could
/// WEAKEN a gate would be a gate the agent controls. This one only ever costs
/// the agent a cold build. The plugin-cache purge has no switch at all.
@Test func theBuildOutputOverrideOnlyEverTurnsProtectionOn() {
    for on in ["1", "true", "TRUE", "yes", "on", " 1 "] {
        #expect(EvalRunner.purgeBuildOutputRequested(
            env: [EvalRunner.purgeBuildOutputEnvKey: on]), "\(on) must enable it")
    }
    // Anything else -- including every spelling of "off" -- is the DEFAULT,
    // which is off. There is deliberately no value that disables anything.
    for off in ["0", "false", "no", "off", "", "maybe"] {
        #expect(!EvalRunner.purgeBuildOutputRequested(
            env: [EvalRunner.purgeBuildOutputEnvKey: off]), "\(off) must leave the default")
    }
    #expect(!EvalRunner.purgeBuildOutputRequested(env: [:]))
}

/// Fail-closed: a purge that cannot be performed is a refusal, not a warning.
/// Continuing would build on exactly the cached artifact the deletion exists to
/// discard.
@Test func aPurgeThatCannotBePerformedIsARefusal() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent(".build").path)
        try? FileManager.default.removeItem(at: directory)
    }
    try plantBuildCache(directory)
    // Make `.build` unwritable, so removing `.build/plugins` from it fails.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.appendingPathComponent(".build").path)

    let failure = EvalRunner.purgePluginCache(in: directory, where: "a fixture")
    #expect(failure?.reason == "plugin_cache_not_purged", "got \(failure?.reason ?? "nil")")
    #expect(failure?.detail.contains(".build/plugins") == true)
}

/// An absent cache is success, not an error: the point of the call is that the
/// directory is gone afterwards, and a repository that has never been built
/// already satisfies that.
@Test func purgingAnAbsentCacheSucceeds() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(EvalRunner.purgePluginCache(in: directory, where: "a fixture") == nil)
    #expect(EvalRunner.purge(
        EvalRunner.buildOutputSubpaths, in: directory, reason: "build_output_not_purged",
        what: "the compiled build output", where: "a fixture") == nil)
}
