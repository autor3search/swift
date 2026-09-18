import Testing
import Foundation
@testable import AutoR3SearchKit

private func cfg(count: Int = 10, benchmarks: [String] = ["A"]) -> Config {
    Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Benchmarks",
           benchmarks: benchmarks, count: count, alpha: 0.05,
           minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
}

@Test func countBelowFourIsRejectedWithAReason() {
    // At n=3 the smallest reachable two-sided p is 0.10; every experiment would
    // DISCARD on a technicality with nothing explaining why.
    #expect(throws: ConfigError.self) { try cfg(count: 3).validate() }
    let message = String(describing: ConfigError.countTooSmall(3))
    #expect(message.contains("4"))
    #expect(message.lowercased().contains("significance") || message.lowercased().contains("reach"))
}

@Test func countOfFourIsAccepted() throws {
    try cfg(count: 4).validate()
}

@Test func emptyBenchmarkListIsRejected() {
    // The tool optimizes what it can measure and refuses to guess.
    #expect(throws: ConfigError.self) { try cfg(benchmarks: []).validate() }
}

@Test func warnsWhenNoKeepIsReachable() {
    // count=4 with 2 benchmarks: alpha/k = 0.025 < floor 0.0286. Unreachable.
    let warning = cfg(count: 4, benchmarks: ["A", "B"]).keepReachabilityWarning()
    #expect(warning != nil)
    #expect(warning!.contains("5"), "must name the count to raise to")
}

@Test func noWarningWhenKeepIsReachable() {
    #expect(cfg(count: 10, benchmarks: ["A", "B", "C"]).keepReachabilityWarning() == nil)
}

@Test func roundTripsThroughYAML() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.yaml")
    try """
    version: 1
    scope:
      - Sources/**
    benchmark_target: Benchmarks
    benchmarks:
      - ParseJSON
    count: 10
    alpha: 0.05
    min_effect_pct: 1.0
    max_regress_pct: 5.0
    timeout_seconds: 600
    """.write(to: url, atomically: true, encoding: .utf8)
    let loaded = try Config.load(url)
    #expect(loaded.benchmarks == ["ParseJSON"])
    #expect(loaded.benchmarkTarget == "Benchmarks")
    #expect(loaded.count == 10)
    try FileManager.default.removeItem(at: dir)
}

// =====================================================================
// MARK: - purge_build_output, and the backward compatibility it must not break
// =====================================================================

/// THE PROPERTY THAT MATTERS MORE THAN THE FEATURE.
///
/// `baseline` records a SHA-256 of `config.yaml`'s BYTES, and gate 2 refuses
/// any mismatch. So a new REQUIRED key would not merely fail to parse on an
/// existing config -- it would be unfixable without re-baselining, because the
/// fix (adding the key) changes the very hash the record pinned. Every
/// in-flight run on the planet would have to be started over.
///
/// Both halves are asserted here against a config.yaml written exactly as it
/// was before the field existed: it still DECODES, it decodes to `false`, and
/// the file on disk is byte-for-byte unchanged by having been read, so the
/// hash a baseline recorded for it still matches.
@Test func aConfigWrittenBeforePurgeBuildOutputExistedStillLoadsAndStillHashesTheSame() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.yaml")

    // Byte-for-byte the shape `init` used to write. No `purge_build_output`.
    let legacy = """
    version: 1
    scope:
      - Sources/**
    benchmark_target: Benchmarks
    benchmarks:
      - ParseJSON
    count: 10
    alpha: 5e-3
    min_effect_pct: 3e+0
    max_regress_pct: 3e+0
    timeout_seconds: 600
    """
    try legacy.write(to: url, atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: url)

    let loaded = try Config.load(url)
    #expect(loaded.purgeBuildOutput == false,
            "an absent purge_build_output must mean off, not a decode failure")
    #expect(loaded.count == 10, "the rest of the config must be unaffected")

    // The bytes gate 2 hashes are untouched by reading them.
    #expect(try Data(contentsOf: url) == before,
            "loading rewrote config.yaml; every in-flight run's configSHA256 would now mismatch")
}

/// Absent and WRONG are different, and only the first is acceptable. This is
/// why the decode is `decodeIfPresent ?? false` rather than a `try?` swallowing
/// everything: `purge_build_output: maybe` is a config the operator got wrong,
/// and silently reading it as `false` would turn a typo into a security switch
/// that is off without anyone being told.
@Test func aMalformedPurgeBuildOutputThrowsRatherThanQuietlyMeaningFalse() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.yaml")

    func write(_ purge: String) throws {
        try """
        version: 1
        scope:
          - Sources/**
        benchmark_target: Benchmarks
        benchmarks:
          - ParseJSON
        count: 10
        alpha: 5e-3
        min_effect_pct: 3e+0
        max_regress_pct: 3e+0
        timeout_seconds: 600
        purge_build_output: \(purge)
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    try write("true")
    #expect(try Config.load(url).purgeBuildOutput == true)

    try write("false")
    #expect(try Config.load(url).purgeBuildOutput == false)

    try write("maybe")
    #expect(throws: (any Error).self) { _ = try Config.load(url) }
}

/// A `Bool` has no invalid value, so `validate()` says nothing about this
/// field -- asserted rather than assumed, because a validator that silently
/// grew an opinion about it would be a surprise at the worst moment.
@Test func purgeBuildOutputHasNothingToValidateInEitherPosition() throws {
    var c = cfg()
    c.purgeBuildOutput = false
    try c.validate()
    c.purgeBuildOutput = true
    try c.validate()
}

/// THE OVERRIDE CAN ONLY TIGHTEN. In many deployments the agent under
/// measurement is the process that invokes `eval` and therefore owns the
/// environment, so the safety of reading this from the environment rests
/// entirely on there being no value that turns anything OFF. `||`, never
/// "env wins".
@Test func theEnvironmentCanOnlyTurnTheBuildOutputPurgeOnNeverOff() {
    let key = EvalRunner.purgeBuildOutputEnvKey
    let off = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "B", benchmarks: ["A"],
                     count: 10, alpha: 0.005, minEffectPct: 3.0, maxRegressPct: 3.0,
                     timeoutSeconds: 600, purgeBuildOutput: false)
    var on = off
    on.purgeBuildOutput = true

    // Config off: the environment is the only way to get the purge.
    #expect(EvalRunner.purgeBuildOutput(config: off, env: [:]) == false)
    #expect(EvalRunner.purgeBuildOutput(config: off, env: [key: "1"]) == true)
    #expect(EvalRunner.purgeBuildOutput(config: off, env: [key: "true"]) == true)
    #expect(EvalRunner.purgeBuildOutput(config: off, env: [key: "YES"]) == true)
    #expect(EvalRunner.purgeBuildOutput(config: off, env: [key: " on "]) == true)
    #expect(EvalRunner.purgeBuildOutput(config: off, env: [key: "0"]) == false)

    // Config ON: NOTHING in the environment may undo it. If any of these ever
    // returns false, the agent has been handed a switch that weakens a gate.
    for value in ["0", "false", "no", "off", "", "  ", "nonsense", "1", "true"] {
        #expect(EvalRunner.purgeBuildOutput(config: on, env: [key: value]) == true,
                "the environment disabled a purge the config required")
    }
    #expect(EvalRunner.purgeBuildOutput(config: on, env: [:]) == true)
}

/// `init` writes the key, at its default, with the price attached -- and the
/// result must survive its own loader, comment and all.
@Test func initWritesPurgeBuildOutputWithItsCostSpelledOut() throws {
    let c = InitRunner.defaultConfig(
        scope: ["Sources/Lib/**"], benchmarkTarget: "Bench", benchmarks: ["B"])
    #expect(c.purgeBuildOutput == false, "the shipped default must be off")

    let text = InitRunner.annotated(try c.serialized())
    #expect(text.contains("purge_build_output: false"))
    #expect(text.contains("# Delete every compiled artifact"),
            "a security switch defaulted to off must say why in the file itself")
    #expect(text.contains("+33.6s"), "the comment must name the measured price")

    // The comment sits ABOVE the key, not inside the value.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let keyIndex = try #require(lines.firstIndex(where: { $0.hasPrefix("purge_build_output:") }))
    #expect(keyIndex > 0 && lines[keyIndex - 1].hasPrefix("#"))

    // And the annotated text is still a config this tool can read.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.yaml")
    try text.write(to: url, atomically: true, encoding: .utf8)
    #expect(try Config.load(url) == c, "init wrote a config it cannot read back")
}

/// Defensive: `annotated` must never guess. Given text with no such key it
/// returns the input untouched, because a comment spliced into the wrong line
/// is a corrupt config while a missing comment is merely cosmetic.
@Test func annotatingTextWithoutTheKeyChangesNothing() {
    let text = "version: 1\ncount: 10\n"
    #expect(InitRunner.annotated(text) == text)
}
