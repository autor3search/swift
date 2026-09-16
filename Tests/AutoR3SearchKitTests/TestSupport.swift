import Foundation
import Testing
@testable import AutoR3SearchKit

/// A git repo with a Package.swift, one benchmark target, one test target, and a config.
///
/// The manifest is a REAL, describable SwiftPM package -- a library target plus a test
/// target, zero external dependencies, so `swift package describe` succeeds fully
/// offline (verified: ~0.75s cold, ~0.14s warm). This matters: `BaselineRunner.run` now
/// treats a `swift package describe` failure as fatal, and this fixture is what all six
/// `BaselineRunnerTests` run against, so it must actually describe. `frozenDirectories`
/// for this manifest is `["Tests/LibTests"]` -- non-empty, so both of `baseline`'s
/// hard-fails (`missingFrozenDirectory`, `emptyFreezeManifest`) stay strict and the
/// freeze set this fixture produces is real, not vacuous.
///
/// `.gitignore` (committed) covers `.build/`, matching what `init` writes for a real
/// repository: the first `baseline` run's `swift package describe` creates `.build` in
/// the repo root, and without this entry a second `BaselineRunner.run` against the same
/// fixture (as `refusesAReusedTag` performs) would trip `dirtyTree` instead of
/// `tagInUse` -- the test would still pass, but for the wrong reason.
func makeGitFixture() throws -> (URL, Git) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Lib"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tests/LibTests"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".autor3search"),
                                            withIntermediateDirectories: true)
    try "public func f() -> Int { 1 }".write(to: dir.appendingPathComponent("Sources/Lib/Lib.swift"),
                                             atomically: true, encoding: .utf8)
    try """
    import Testing
    @testable import Lib

    @Test func fReturnsOne() {
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
    """.write(to: dir.appendingPathComponent("Package.swift"),
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
    """.write(to: dir.appendingPathComponent(".autor3search/config.yaml"),
              atomically: true, encoding: .utf8)
    try "one".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try ".build/\n".write(to: dir.appendingPathComponent(".gitignore"),
                          atomically: true, encoding: .utf8)
    let sh = URL(fileURLWithPath: "/bin/sh")
    let r = try Subprocess.run(sh, ["-c", """
        git init -q . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m one
        """], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "fixture setup failed: \(r.stderr)")
    return (dir, Git(repo: dir))
}

/// Keeps tests off the real user cache directory.
func isolatedStateEnv() -> [String: String] {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    return [StateHome.envKey: d.path]
}
