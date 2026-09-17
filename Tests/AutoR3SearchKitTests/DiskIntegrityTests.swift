import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/DiskIntegrityTests.swift
//
// ONE ROOT CAUSE, THREE ATTACKS. Gate 1 derives what the candidate changed
// from GIT's view (`git diff --name-only`). Gate 2b derives whether the tree is
// clean from GIT's view (`git status`). SwiftPM compiles THE DISK. And the
// adversary is the agent being measured, which owns git's view of its own
// repository -- ignore rules, `.git/info/exclude`, `update-index` flags.
//
// Every test here asserts THE PREMISE first (that git really is blind to the
// thing being planted) before asserting the refusal, because a test that only
// proves the gate fires does not prove the gate was ever needed.
//
// All of them sample through `ZeroCallSource`, which records every call, so
// "nothing was measured" is a counted 0 rather than an inference.

/// Counts every sample it is asked for. The assertion is always `== 0`: these
/// gates exist to reject before the first build and the first measurement.
private final class ZeroCallSource: MetricSource, @unchecked Sendable {
    var calls = 0
    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        calls += 1
        return 100.0
    }
}

private func sh(_ script: String, in repo: URL) throws {
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script],
                               cwd: repo, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "\(script): \(r.stderr)")
}

// =========================================================================
// MARK: - Attack A: a planted, GITIGNORED source file
// =========================================================================

/// Commit `Sources/.gitignore` naming `*.gen.swift` -- in scope, not a
/// manifest, so gate 1 passes it -- then plant `Sources/Lib/Boost.gen.swift`.
/// `git status --porcelain` is EMPTY. Gate 4's new-file scan only walks the
/// FROZEN directories, so it never looks in `Sources/`. `swift build` compiles
/// the file.
///
/// The damage is not one bad measurement. The pinned measurement worktree is a
/// checkout of a COMMIT and never contains the file, so it manufactures a win
/// on every subsequent eval, credited to commits that do not contain it -- and
/// `git add -A` will not commit it and `git reset --hard` will not remove it,
/// so it does not even wash out between experiments.
///
/// Measured end to end against the real binary before this gate existed:
/// `exit_code=0, verdict keep, ratio 0.113`, from a repository whose
/// `git status --porcelain` printed nothing at all.
@Test func aPlantedGitignoredSourceFileIsRefusedAndNeverMeasured() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    // The ignore rule must predate the freeze only in the sense that it has to
    // be committed; committing it AFTER baseline is exactly the agent's move,
    // and `Sources/**` is in scope, so gate 1 waves it through.
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    try "*.gen.swift\n".write(to: repo.appendingPathComponent("Sources/.gitignore"),
                              atomically: true, encoding: .utf8)
    try sh("git add -- Sources/.gitignore && git commit -q -m generated", in: repo)

    try "public func boosted() -> Int { 2 }\n".write(
        to: repo.appendingPathComponent("Sources/Lib/Boost.gen.swift"),
        atomically: true, encoding: .utf8)

    // THE PREMISE: every path-based gate is blind.
    #expect(try git.isClean(), "the planted file must be invisible to a plain git status")
    let changed = try git.changedPaths(since: try BaselineRecord.load(
        try StateHome(repo: repo, env: env).baselineRecordURL(tag: "t")).frozenCommit)
    #expect(!changed.contains("Sources/Lib/Boost.gen.swift"),
            "gate 1 must not see it, or this test proves nothing: \(changed)")

    let source = ZeroCallSource()
    let v = try EvalRunner.run(repo: repo, env: env, source: source, now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "dirty_working_tree", "got \(v.reason ?? "nil")")
    #expect(v.warnings.first?.contains("Sources/Lib/Boost.gen.swift") == true,
            "the refusal must NAME the offending path: \(v.warnings)")
    #expect(source.calls == 0, "nothing may be measured: \(source.calls) samples taken")
}

/// The same hole with no repository file at all. `.git/info/exclude` is
/// untracked, is not part of the repository's content, cannot be committed and
/// cannot be reviewed -- so neither of the two previously-closed index-flag
/// bypasses covers it and no path-based gate has anything to look at.
@Test func aFilePlantedBehindGitInfoExcludeIsRefusedAndNeverMeasured() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    let exclude = repo.appendingPathComponent(".git/info/exclude")
    try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "Sources/Lib/Boost.swift\n".write(to: exclude, atomically: true, encoding: .utf8)
    try "public func boosted() -> Int { 2 }\n".write(
        to: repo.appendingPathComponent("Sources/Lib/Boost.swift"),
        atomically: true, encoding: .utf8)
    try makeInScopeCommit(repo, "innocent looking")

    #expect(try git.isClean(), "THE PREMISE: .git/info/exclude hides it from gate 2b")

    let source = ZeroCallSource()
    let v = try EvalRunner.run(repo: repo, env: env, source: source, now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "dirty_working_tree", "got \(v.reason ?? "nil")")
    #expect(v.warnings.first?.contains("Sources/Lib/Boost.swift") == true,
            "the refusal must NAME the offending path: \(v.warnings)")
    #expect(source.calls == 0)
}

/// The other direction, and the reason the allowlist has to be exactly four
/// paths rather than "anything ignored": `eval` writes `results.tsv`, `run.log`
/// and `.autor3search/profiles/` into the repository itself and `swift build`
/// writes `.build/`, all of them gitignored by `init`. If those tripped the
/// gate, the SECOND eval on every repository would refuse.
@Test func theHarnessOwnIgnoredOutputsDoNotTripTheDirtyTreeGate() throws {
    let (repo, git) = try makeGitFixture()
    defer { try? FileManager.default.removeItem(at: repo) }

    // The fixture's committed .gitignore covers .build/, results.tsv and
    // run.log; `init` adds .autor3search/profiles/, so add it the same way.
    let gitignore = repo.appendingPathComponent(".gitignore")
    try (try String(contentsOf: gitignore, encoding: .utf8) + ".autor3search/profiles/\n")
        .write(to: gitignore, atomically: true, encoding: .utf8)
    try sh("git add -- .gitignore && git commit -q -m ignore", in: repo)

    try "1\tabc\n".write(to: repo.appendingPathComponent("results.tsv"),
                         atomically: true, encoding: .utf8)
    try "log\n".write(to: repo.appendingPathComponent("run.log"), atomically: true, encoding: .utf8)
    for dir in [".build", ".autor3search/profiles"] {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(dir),
                                                withIntermediateDirectories: true)
        try "x".write(to: repo.appendingPathComponent(dir + "/x"), atomically: true, encoding: .utf8)
    }

    // git really does report all four as present-but-ignored...
    let entries = try git.status(includingIgnored: true)
    let allIgnored = entries.allSatisfy { $0.isIgnored }
    #expect(allIgnored, "the premise: nothing here is merely uncommitted -- \(entries)")
    #expect(!entries.isEmpty)
    // ...and the gate tolerates exactly these.
    #expect(EvalRunner.dirtyTreeFailure(git: git) == nil,
            "the harness's own outputs must not refuse every eval after the first")

    // One path outside the allowlist, and it refuses again.
    try "\nnotes.md\n".write(to: gitignore, atomically: true, encoding: .utf8)
    try sh("git add -- .gitignore && git commit -q -m ignore2", in: repo)
    try "secretly compiled".write(to: repo.appendingPathComponent("notes.md"),
                                  atomically: true, encoding: .utf8)
    let failure = EvalRunner.dirtyTreeFailure(git: git)
    #expect(failure?.reason == "dirty_working_tree")
    #expect(failure?.detail.contains("notes.md") == true)
}

// =========================================================================
// MARK: - Attack C: --assume-unchanged on an OUT-OF-SCOPE tracked file
// =========================================================================

/// Gate 1 enforces `scope` purely through git's path accounting, so one
/// `update-index` flag defeats gate 1 AND gate 2b at once, and the existing
/// hash inventory covers only manifests.
///
/// Measured end to end against the real binary before this gate existed, on a
/// demo package with a benchmark helper target holding the workload size and
/// `scope: [Sources/Demo/**]` exactly as the project documents: the helper's
/// repeat count set from 1750 to 1, plus a COMMENT-ONLY in-scope commit, gave
/// `exit_code=0, verdict keep, ratio 0.000737`. The project's README claimed
/// "`scope` closes the benchmark-helper hole"; it did not.
@Test func anAssumeUnchangedOutOfScopeEditIsRefusedAndNeverMeasured() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    // `a.txt` is committed, tracked, and outside the fixture's `Sources/**`
    // scope -- the same shape as a benchmark helper's fixture data.
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    try sh("git update-index --assume-unchanged a.txt", in: repo)
    try "a much smaller workload".write(to: repo.appendingPathComponent("a.txt"),
                                        atomically: true, encoding: .utf8)
    try makeInScopeCommit(repo, "innocent looking")

    // THE PREMISE: both path-based gates are blind.
    #expect(try git.isClean(), "the bypass did not work -- gate 2b would have caught this")
    let changed = try git.changedPaths(since: record.frozenCommit)
    #expect(!changed.contains("a.txt"), "the bypass did not work -- gate 1 would have caught this")

    let source = ZeroCallSource()
    let v = try EvalRunner.run(repo: repo, env: env, source: source, now: Date.init)
    #expect(v.kind == .fail)
    #expect(v.reason == "out_of_scope", "got \(v.reason ?? "nil")")
    #expect(v.warnings.first?.contains("a.txt") == true,
            "the refusal must NAME the offending path: \(v.warnings)")
    #expect(source.calls == 0)
}

/// Deleting an out-of-scope file is as much a change as editing one -- a
/// benchmark helper's fixture data that is simply gone changes what is
/// measured -- and `--assume-unchanged` hides a deletion exactly as well.
@Test func anAssumeUnchangedOutOfScopeDeletionIsRefused() throws {
    let (repo, git) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    try sh("git update-index --assume-unchanged a.txt", in: repo)
    try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
    try makeInScopeCommit(repo, "innocent looking")
    #expect(try git.isClean(), "THE PREMISE: the deletion is hidden from gate 2b")

    let source = ZeroCallSource()
    let v = try EvalRunner.run(repo: repo, env: env, source: source, now: Date.init)
    #expect(v.reason == "out_of_scope", "got \(v.reason ?? "nil")")
    #expect(v.warnings.first?.contains("missing: a.txt") == true, "\(v.warnings)")
    #expect(source.calls == 0)
}

/// A CASE-VARIANT MANIFEST, closed by the same inventory.
///
/// `ScopeGate.isManifestPath` matches case-SENSITIVELY, which is correct for
/// git-reported paths and is its documented rationale -- but APFS is
/// case-insensitive, so `swift package describe` honours a file spelled
/// `PACKAGE@SWIFT-6.4.SWIFT` exactly as it would `Package@swift-6.4.swift`.
/// The manifest inventory reuses `isManifestPath` and so cannot see it. This
/// inventory does not care what the file is called: it is outside `scope`, it
/// was not there at baseline, so it is an EXTRA file.
@Test func aCaseVariantManifestAppearsAsAnExtraFileOutsideScope() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)

    let variant = "PACKAGE@SWIFT-6.4.SWIFT"
    #expect(!ScopeGate.isManifestPath(variant),
            "THE PREMISE: the manifest predicate is case-sensitive and does not match this")
    try "// a manifest under a spelling isManifestPath does not recognise\n".write(
        to: repo.appendingPathComponent(variant), atomically: true, encoding: .utf8)

    #expect(EvalRunner.manifestInventoryFailure(repo: repo, record: record) == nil,
            "THE PREMISE: the manifest inventory cannot see it either")

    let failure = EvalRunner.treeInventoryFailure(
        repo: repo, record: record, scope: ["Sources/**"])
    #expect(failure?.reason == "out_of_scope")
    #expect(failure?.detail.contains("extra:   \(variant)") == true, "\(failure?.detail ?? "nil")")
}

/// "There is no record" must not read as "there is nothing to check". A
/// `BaselineRecord` written before this field existed is unprotected against
/// every attack above, so `eval` refuses it rather than waving it through on an
/// empty inventory -- the same ruling the manifest inventory already made.
@Test func aBaselineWithNoTreeInventoryIsRefusedRatherThanWavedThrough() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    var record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(record.treeSHA256 != nil, "a fresh baseline must carry one")

    record.treeSHA256 = nil
    let failure = EvalRunner.treeInventoryFailure(
        repo: repo, record: record, scope: ["Sources/**"])
    #expect(failure?.reason == "baseline_predates_tree_inventory")

    // And the older record shape still DECODES, so the refusal is a refusal
    // and not a crash on an unreadable file.
    let json = """
        {"tag":"t","frozenCommit":"a","measurementCommit":"a","configSHA256":"c",
         "packageSwiftSHA256":"p","packageResolvedSHA256":"r","toolVersion":"0"}
        """
    let old = try JSONDecoder().decode(BaselineRecord.self, from: Data(json.utf8))
    #expect(old.treeSHA256 == nil)
    #expect(old.manifestSHA256 == nil)
}

/// The other direction: an untouched repository must PASS, and an in-scope
/// change -- the thing the agent is actually supposed to make -- must not be
/// reported by this gate at all.
@Test func theTreeInventoryPassesAnUntouchedRepositoryAndIgnoresInScopeWork() throws {
    let (repo, _) = try makeGitFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }
    let record = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    #expect(EvalRunner.treeInventoryFailure(
        repo: repo, record: record, scope: ["Sources/**"]) == nil)

    // Rewriting an in-scope file, and adding a new one, are both invisible here.
    try "public func f() -> Int { 1 } // faster\n".write(
        to: repo.appendingPathComponent("Sources/Lib/Lib.swift"), atomically: true, encoding: .utf8)
    try "public func g() -> Int { 2 }\n".write(
        to: repo.appendingPathComponent("Sources/Lib/New.swift"), atomically: true, encoding: .utf8)
    #expect(EvalRunner.treeInventoryFailure(
        repo: repo, record: record, scope: ["Sources/**"]) == nil,
            "in-scope content is what the agent is supposed to change")
}

/// What `treeInventory` covers, asserted directly rather than through a
/// verdict: `.git` and `.build` are never walked, the harness's own outputs are
/// excluded, in-scope paths are excluded, and everything else is hashed.
@Test func theTreeInventoryCoversEverythingOutsideScopeAndNothingElse() throws {
    let (repo, _) = try makeGitFixture()
    defer { try? FileManager.default.removeItem(at: repo) }

    for dir in [".build/checkouts/dep", ".autor3search/profiles"] {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(dir),
                                                withIntermediateDirectories: true)
    }
    try "// a dependency's own manifest\n".write(
        to: repo.appendingPathComponent(".build/checkouts/dep/Package.swift"),
        atomically: true, encoding: .utf8)
    try "{}".write(to: repo.appendingPathComponent(".autor3search/profiles/p.json"),
                   atomically: true, encoding: .utf8)
    try "1\tx\n".write(to: repo.appendingPathComponent("results.tsv"),
                       atomically: true, encoding: .utf8)
    try "log".write(to: repo.appendingPathComponent("run.log"), atomically: true, encoding: .utf8)

    let inventory = try BaselineRunner.treeInventory(repo: repo, scope: ["Sources/**"])

    #expect(inventory["a.txt"] != nil, "an out-of-scope tracked file must be inventoried")
    #expect(inventory["Package.swift"] != nil)
    #expect(inventory["Tests/LibTests/LibTests.swift"] != nil,
            "the frozen tests are out of scope here and are covered too")
    #expect(inventory[".autor3search/config.yaml"] != nil)
    #expect(inventory["Sources/Lib/Lib.swift"] == nil, "in scope: the agent may change it")
    #expect(inventory[".build/checkouts/dep/Package.swift"] == nil,
            ".build holds every dependency's checkout and SwiftPM rewrites it at will")
    #expect(inventory.keys.contains { $0.hasPrefix(".git/") } == false,
            "git's own object store must never be hashed")
    #expect(inventory["results.tsv"] == nil, "the harness writes this on every eval")
    #expect(inventory["run.log"] == nil)
    #expect(inventory[".autor3search/profiles/p.json"] == nil)
    #expect(inventory["a.txt"]?.count == 64, "regular files are recorded as a SHA-256")
}

/// A symbolic link is recorded by its DESTINATION, never by the bytes it points
/// at. Reading through it would let the recorded value describe a file outside
/// the repository, so re-aiming the link would change what is compiled without
/// changing the recorded value -- and `Data(contentsOf:)` on a fifo blocks
/// forever, which is a one-line denial of service against an unattended run.
@Test func theTreeInventoryRecordsLinksByDestinationAndNeverReadsThroughThem() throws {
    let (repo, _) = try makeGitFixture()
    defer { try? FileManager.default.removeItem(at: repo) }

    try FileManager.default.createSymbolicLink(
        at: repo.appendingPathComponent("link.txt"),
        withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    let first = try BaselineRunner.treeInventory(repo: repo, scope: ["Sources/**"])
    #expect(first["link.txt"] == "symlink:/etc/hosts")

    // Re-aiming the link is itself the change.
    try FileManager.default.removeItem(at: repo.appendingPathComponent("link.txt"))
    try FileManager.default.createSymbolicLink(
        at: repo.appendingPathComponent("link.txt"),
        withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    let second = try BaselineRunner.treeInventory(repo: repo, scope: ["Sources/**"])
    #expect(second["link.txt"] != first["link.txt"])
}

/// The allowlist is matched case-SENSITIVELY, and on a case-insensitive
/// filesystem that is the safe direction. APFS preserves the spelling it was
/// given, so the enumerator reports the real on-disk name: a write into an
/// existing `.build` comes back spelled `.build` and matches. What a
/// case-insensitive comparison would add is the ability to create a
/// genuinely-new directory differing from an allowlisted one only by case and
/// have it silently exempted. Under-matching only ever produces a loud refusal.
@Test func theHarnessOutputAllowlistIsCaseSensitive() {
    #expect(BaselineRunner.isHarnessOutput(".build"))
    #expect(BaselineRunner.isHarnessOutput(".build/"))
    #expect(BaselineRunner.isHarnessOutput(".build/release/Bench"))
    #expect(BaselineRunner.isHarnessOutput("results.tsv"))
    #expect(BaselineRunner.isHarnessOutput(".autor3search/profiles/a.json"))
    #expect(!BaselineRunner.isHarnessOutput(".BUILD/x"))
    #expect(!BaselineRunner.isHarnessOutput("Results.tsv"))
    #expect(!BaselineRunner.isHarnessOutput(".autor3search/config.yaml"))
    // A near-miss that merely shares a prefix is not under the directory.
    #expect(!BaselineRunner.isHarnessOutput(".buildkite/pipeline.yml"))
}

// =========================================================================
// MARK: - Attack D: the state store is same-user and writable
// =========================================================================

/// `restore` used to copy the store's bytes into the repository WITHOUT ever
/// comparing them to the `manifest[rel]` SHA-256 it was already carrying.
///
/// Measured end to end against the real binary before this pass existed: one
/// `sed -i` on the stored `Bench.swift` (mode 0644, same user) set the
/// benchmark's workload from 1750 repeats to 1, and a comment-only in-scope
/// commit then returned `exit_code=0, verdict keep, ratio 0.000717` -- with the
/// repository afterwards containing the attacker's benchmark. `eval` installed
/// it and then measured it.
@Test func restoreRefusesStoreBytesThatDoNotMatchTheRecordedHash() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let store = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: store)
    }
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "count: 1750".write(to: tests.appendingPathComponent("Bench.swift"),
                            atomically: true, encoding: .utf8)
    try "assert(real)".write(to: tests.appendingPathComponent("T.swift"),
                             atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    // The agent has a shell and the store is 0644, same user.
    try "count: 1".write(to: store.appendingPathComponent("Tests/DemoTests/Bench.swift"),
                         atomically: true, encoding: .utf8)

    #expect(throws: FrozenError.self) { try snap.restore(repo: repo, from: store) }
    #expect(try String(contentsOf: tests.appendingPathComponent("Bench.swift"), encoding: .utf8)
            == "count: 1750",
            "restore installed the attacker's benchmark over the repository")
}

/// A refusal must abort the WHOLE restore, not leave the first half of the
/// frozen set already written back. Verification is a separate pass over every
/// file before a single byte is written, so a tampered file discovered at
/// `Z.swift` cannot leave `A.swift` restored -- which would otherwise mean an
/// eval that refuses still half-applied a restore whose source it does not
/// trust.
@Test func aTamperedStoreFileStopsTheRestoreBeforeAnyFileIsWritten() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let store = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: store)
    }
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "A original".write(to: tests.appendingPathComponent("A.swift"),
                           atomically: true, encoding: .utf8)
    try "Z original".write(to: tests.appendingPathComponent("Z.swift"),
                           atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    // The agent edits both the repository's A (which restore would fix) and
    // the STORE's Z (which restore must refuse). "A.swift" sorts first.
    try "A weakened".write(to: tests.appendingPathComponent("A.swift"),
                           atomically: true, encoding: .utf8)
    try "Z tampered".write(to: store.appendingPathComponent("Tests/DemoTests/Z.swift"),
                           atomically: true, encoding: .utf8)

    #expect(throws: FrozenError.self) { try snap.restore(repo: repo, from: store) }
    #expect(try String(contentsOf: tests.appendingPathComponent("A.swift"), encoding: .utf8)
            == "A weakened",
            "a restore whose source is not trusted must write NOTHING, not a prefix of the set")
}

/// `snapshot` refuses to freeze a symbolic link, so one in the store was not
/// written by `baseline`. Following it would take the restored bytes from
/// wherever it now points -- and a link whose target happens to hash correctly
/// would otherwise pass the content check.
@Test func restoreRefusesASymbolicLinkInTheStore() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let store = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: store)
    }
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "assert(real)".write(to: tests.appendingPathComponent("T.swift"),
                             atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    let elsewhere = store.appendingPathComponent("elsewhere.swift")
    try "assert(real)".write(to: elsewhere, atomically: true, encoding: .utf8)
    let stored = store.appendingPathComponent("Tests/DemoTests/T.swift")
    try FileManager.default.removeItem(at: stored)
    try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: elsewhere)

    #expect(throws: FrozenError.symlinkInStore("Tests/DemoTests/T.swift")) {
        try snap.restore(repo: repo, from: store)
    }
}

/// An untampered store still restores, or the check above would be a
/// regression rather than a fix.
@Test func restoreStillWorksWhenTheStoreMatchesItsManifest() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let store = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: store)
    }
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    let file = tests.appendingPathComponent("T.swift")
    try "assert(real)".write(to: file, atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    try "assert(true) // weakened".write(to: file, atomically: true, encoding: .utf8)
    try snap.restore(repo: repo, from: store)
    #expect(try String(contentsOf: file, encoding: .utf8) == "assert(real)")
}
