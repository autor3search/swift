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

// =========================================================================
// MARK: - Package.resolved: the dependency pin
// =========================================================================
//
// THE DEFECT THESE BIND. `swift package describe` (all `init` ran) exits 0 and
// writes no `Package.resolved`; `swift build -c release --product X` writes one
// into the package ROOT. So on any repository with source-control dependencies
// and no tracked lockfile, `baseline` hashed a file that did not exist --
// `sha256File` returned the hash of ZERO BYTES, a legitimate-looking 64-hex pin
// that pins nothing -- and the FIRST `eval`'s own build then created the file.
// From then on, permanently: commit it and `ScopeGate.isManifestPath` answers
// `manifest_change_rejected`; leave it and gate 2b answers `dirty_working_tree`.
// `frozenCommit` never advances, so neither door reopens. Observed live as a
// `fail/manifest_change_rejected` immediately after a successful KEEP.

/// A git fixture whose package has a REAL external dependency: a second, local
/// git repository consumed by `file://` URL, so this is a genuine
/// `sourceControl` dependency (verified: `swift package describe` reports
/// `"type": "sourceControl"` for it, and `swift package resolve` writes a
/// `Package.resolved` with `"kind": "localSourceControl"`) without needing the
/// network. Everything else matches `makeGitFixture`: two executable products
/// `baseline`'s warm build names, one test target so the freeze manifest is
/// non-empty, and a `.gitignore` covering `.build/`.
///
/// Deliberately does NOT create or commit `Package.resolved` -- reproducing
/// exactly the state a real repository is in after a `swift package describe`-
/// only `init`.
///
/// Both directories live under one parent so a single removal cleans up the
/// repository AND the dependency it points at; the returned `root` is that parent.
func makeDependentGitFixture() throws -> (root: URL, repo: URL) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let dep = root.appendingPathComponent("dep")
    let repo = root.appendingPathComponent("repo")
    let sh = URL(fileURLWithPath: "/bin/sh")

    try fm.createDirectory(at: dep.appendingPathComponent("Sources/DepLib"),
                           withIntermediateDirectories: true)
    try """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "DepLib",
        products: [.library(name: "DepLib", targets: ["DepLib"])],
        targets: [.target(name: "DepLib")]
    )
    """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "public func depThing() -> Int { 7 }\n".write(
        to: dep.appendingPathComponent("Sources/DepLib/DepLib.swift"), atomically: true, encoding: .utf8)
    let depSetup = try Subprocess.run(sh, ["-c", """
        git init -q -b main . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m dep && git tag 1.0.0
        """], cwd: dep, env: nil, timeout: 120)
    #expect(depSetup.exitCode == 0, "dependency repo setup failed: \(depSetup.stderr)")

    for sub in ["Sources/Lib", "Sources/Bench", "Sources/BenchmarkTool", "Tests/LibTests", ".autor3search"] {
        try fm.createDirectory(at: repo.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "fixture",
        products: [
            .executable(name: "Bench", targets: ["Bench"]),
            .executable(name: "BenchmarkTool", targets: ["BenchmarkTool"]),
        ],
        dependencies: [
            .package(url: "file://\(dep.path)", from: "1.0.0"),
        ],
        targets: [
            .target(name: "Lib", dependencies: [.product(name: "DepLib", package: "dep")]),
            .executableTarget(name: "Bench"),
            .executableTarget(name: "BenchmarkTool"),
            .testTarget(name: "LibTests", dependencies: ["Lib"]),
        ]
    )
    """.write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "import DepLib\npublic func f() -> Int { depThing() }\n".write(
        to: repo.appendingPathComponent("Sources/Lib/Lib.swift"), atomically: true, encoding: .utf8)
    try "print(\"bench\")\n".write(
        to: repo.appendingPathComponent("Sources/Bench/main.swift"), atomically: true, encoding: .utf8)
    try "print(\"tool\")\n".write(
        to: repo.appendingPathComponent("Sources/BenchmarkTool/main.swift"), atomically: true, encoding: .utf8)
    try """
    import Testing
    @testable import Lib

    @Test func fIsSeven() {
        #expect(f() == 7)
    }
    """.write(to: repo.appendingPathComponent("Tests/LibTests/LibTests.swift"),
              atomically: true, encoding: .utf8)
    try """
    version: 1
    scope:
      - Sources/**
    benchmark_target: Bench
    benchmarks:
      - A
    count: 10
    alpha: 0.05
    min_effect_pct: 1.0
    max_regress_pct: 5.0
    timeout_seconds: 600
    """.write(to: repo.appendingPathComponent(".autor3search/config.yaml"),
              atomically: true, encoding: .utf8)
    try ".build/\nresults.tsv\nrun.log\n".write(
        to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

    let repoSetup = try Subprocess.run(sh, ["-c", """
        git init -q -b main . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m one
        """], cwd: repo, env: nil, timeout: 120)
    #expect(repoSetup.exitCode == 0, "dependent fixture setup failed: \(repoSetup.stderr)")
    return (root, repo)
}

/// Hashing a file that is not there must not silently produce the hash of
/// nothing. `e3b0c442...` is a perfectly well-formed SHA-256 and reads, in
/// `baseline.json`, exactly like a real pin -- which is how "this repository
/// has no lockfile" became indistinguishable from "this repository's lockfile
/// is empty", and how `baseline` came to report success while pinning no
/// dependencies at all.
@Test func sha256OfAMissingFileIsRefusedRatherThanHashedAsNothing() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try withTempDirectories(dir) {
        let missing = dir.appendingPathComponent("Package.resolved")
        #expect(throws: (any Error).self) { _ = try BaselineRunner.sha256File(missing) }
    }
}

/// THE REFUSAL. A package with external dependencies and no lockfile must not
/// be baselined at all: the pin gate 2 exists to hold still would be pinning
/// nothing, and the first `eval`'s build would create the file and brick every
/// experiment after it.
@Test func baselineRefusesAPackageWithDependenciesAndNoLockfile() throws {
    let (root, repo) = try makeDependentGitFixture()
    let env = isolatedStateEnv()
    try withTempDirectories(root, URL(fileURLWithPath: env[StateHome.envKey] ?? "/dev/null")) {
        #expect(!FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("Package.resolved").path),
                "the fixture must start with no lockfile -- that is the state being refused")
        do {
            _ = try BaselineRunner.run(repo: repo, tag: "nolock", env: env)
            Issue.record("expected baseline to refuse a dependency-bearing package with no lockfile")
        } catch let error as BaselineError {
            #expect("\(error)".contains("Package.resolved"),
                    "the refusal must name the file the operator has to commit: \(error)")
        }
    }
}

/// THE EDGE CASE THAT MUST KEEP WORKING. A package with no external
/// dependencies legitimately has no `Package.resolved` and SwiftPM will never
/// create one (verified: `swift package resolve` and `swift build -c release`
/// both exit 0 and write no lockfile for such a package). Refusing here would
/// be a worse bug than the one being fixed, so `baseline` must still succeed --
/// and must record "absent", NOT the hash of zero bytes.
@Test func baselineStillSucceedsForADependencyFreePackageAndRecordsAbsenceHonestly() throws {
    let (repo, _) = try makeGitFixture()
    try withTempDirectories(repo) {
        let record = try BaselineRunner.run(repo: repo, tag: "nodeps", env: isolatedStateEnv())
        #expect(!Lockfile.isEmptyDataPin(record.packageResolvedSHA256),
                "a missing lockfile must never be recorded as the hash of empty data")
        #expect(record.packageResolvedSHA256 == Lockfile.absentPin,
                "got \(record.packageResolvedSHA256)")
    }
}

/// A repository that DOES track its lockfile is pinned to that file's real
/// bytes -- the thing the whole fix exists to make true.
@Test func baselinePinsTheRealLockfileWhenOneIsTracked() throws {
    let (root, repo) = try makeDependentGitFixture()
    let env = isolatedStateEnv()
    try withTempDirectories(root, URL(fileURLWithPath: env[StateHome.envKey] ?? "/dev/null")) {
        try InitRunner.ensureLockfileTracked(repo: repo)
        let record = try BaselineRunner.run(repo: repo, tag: "locked", env: env)
        let expected = try BaselineRunner.sha256File(repo.appendingPathComponent("Package.resolved"))
        #expect(record.packageResolvedSHA256 == expected)
        #expect(record.packageResolvedSHA256.count == 64)
        #expect(!Lockfile.isEmptyDataPin(record.packageResolvedSHA256))
    }
}
