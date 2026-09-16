import Foundation
import Testing
@testable import AutoR3SearchKit

/// A git repo with a Package.swift, one benchmark target, one test target, and a config.
func makeGitFixture() throws -> (URL, Git) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Lib"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".autor3search"),
                                            withIntermediateDirectories: true)
    try "public func f() -> Int { 1 }".write(to: dir.appendingPathComponent("Sources/Lib/Lib.swift"),
                                             atomically: true, encoding: .utf8)
    try "// swift-tools-version: 6.0\n".write(to: dir.appendingPathComponent("Package.swift"),
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
