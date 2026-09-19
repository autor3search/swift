import Foundation
import Yams

/// The frozen shape of `autor3search.yaml`. Order of properties matters:
/// later tasks construct this with the memberwise initialiser using these
/// exact labels in this exact order.
public struct Config: Codable, Equatable, Sendable {
    public var version: Int
    public var scope: [String]
    public var benchmarkTarget: String
    public var benchmarks: [String]
    public var count: Int
    public var alpha: Double
    public var minEffectPct: Double
    public var maxRegressPct: Double
    public var timeoutSeconds: Int

    /// Delete EVERY compiled artifact under `.build` before each side is
    /// built, not just the build-tool plugin cache that is deleted
    /// unconditionally. Off by default.
    ///
    /// WHAT IT BUYS. `.build`'s output tree is not hashed by any gate and
    /// cannot usefully be: llbuild decides what to rebuild from recorded input
    /// signatures, so an object file or a linked binary belonging to a module
    /// whose sources did not change is REUSED rather than recompiled, and an
    /// agent that can write into `.build` can put code into the measured
    /// binary that nothing verified. Setting this makes every artifact come
    /// from sources gates 2a/2b/2c/2d have hashed.
    ///
    /// WHAT IT COSTS. Measured: about **+33.6 s** on one end-to-end eval of
    /// `Fixtures/DemoPackage`, roughly doubling an experiment. `checkouts/`,
    /// `repositories/` and `artifacts/` survive the purge, so it is a cold
    /// BUILD and not a re-resolve -- no network, nothing re-cloned. That cost
    /// is why it is opt-in and why the residual is documented rather than
    /// silently paid by everyone.
    ///
    /// OPTIONAL ON DECODE, ALWAYS. See `init(from:)`: a `config.yaml` written
    /// before this field existed must keep decoding, because `baseline`
    /// records a SHA-256 of that file's bytes and gate 2 refuses a mismatch.
    /// A required key here would not merely fail to parse -- it would brick
    /// every in-flight run, since the fix (adding the key) changes the hash
    /// the baseline pinned.
    public var purgeBuildOutput: Bool

    /// The directory of the SwiftPM package that declares `benchmarkTarget`,
    /// relative to the repository root. `nil` means the repository root
    /// itself, which is exactly what every configuration written before this
    /// field existed meant and still means.
    ///
    /// WHY IT EXISTS. `init` used to discover benchmark targets by scanning
    /// the ROOT `Package.swift` for a target carrying the `Benchmark` product
    /// dependency. Essentially no real adopter of `ordo-one/package-benchmark`
    /// lays a repository out that way. The convention the ecosystem actually
    /// uses is a NESTED package: `Benchmarks/Package.swift`, declaring
    /// `.package(path: "../")` plus the benchmark dependency, with the
    /// benchmark target's sources under `Benchmarks/Benchmarks/<Target>/`.
    /// `apple/swift-asn1`, `apple/swift-log`, `GraphQLSwift/GraphQL` and
    /// `CoreOffice/XMLCoder` all do this, and NONE of them has a benchmark
    /// target in its root package -- so `init` answered "No benchmarks found"
    /// on every one of them while seven real benchmarks sat in the tree.
    ///
    /// WHAT IT CHANGES. Everything that addresses the benchmark package --
    /// `swift package describe` for target discovery, the release build of
    /// the benchmark target and `BenchmarkTool`, the `.build/release/`
    /// directory gate 8 launches out of, the `.build/checkouts` gate 2d
    /// verifies, the `.build/plugins` gate 4b purges -- is rooted at
    /// `<repo>/<benchmarkPackagePath>` instead of `<repo>`. `swift test` is
    /// NOT: the library's tests are the correctness contract and they live in
    /// the ROOT package, so gate 6 still runs there.
    ///
    /// VALIDATED, not merely stored. It must be relative, must not escape the
    /// repository (no `..`, no absolute path), and must name a directory that
    /// actually contains a `Package.swift`. See
    /// `ConfigError.badBenchmarkPackagePath` and `BenchmarkPackage.validate`.
    ///
    /// OPTIONAL ON DECODE, ALWAYS -- the same rule, for the same reason, as
    /// `purgeBuildOutput`: `baseline` records a SHA-256 of `config.yaml`'s
    /// bytes and gate 2 refuses a mismatch, so a REQUIRED key here would not
    /// merely fail to parse, it would brick every in-flight run, because the
    /// fix (adding the key) changes the hash the baseline pinned.
    public var benchmarkPackagePath: String?

    /// The memberwise initialiser. `purgeBuildOutput` and
    /// `benchmarkPackagePath` are the two parameters with defaults,
    /// deliberately: the file's own header says later code constructs this
    /// with these exact labels in this exact order, and giving the new fields
    /// defaults keeps every one of those call sites -- and every test fixture
    /// -- compiling unchanged. A new REQUIRED parameter would have been a
    /// churn of a dozen files to express "the repository root".
    public init(
        version: Int,
        scope: [String],
        benchmarkTarget: String,
        benchmarks: [String],
        count: Int,
        alpha: Double,
        minEffectPct: Double,
        maxRegressPct: Double,
        timeoutSeconds: Int,
        purgeBuildOutput: Bool = false,
        benchmarkPackagePath: String? = nil
    ) {
        self.benchmarkPackagePath = benchmarkPackagePath
        self.version = version
        self.scope = scope
        self.benchmarkTarget = benchmarkTarget
        self.benchmarks = benchmarks
        self.count = count
        self.alpha = alpha
        self.minEffectPct = minEffectPct
        self.maxRegressPct = maxRegressPct
        self.timeoutSeconds = timeoutSeconds
        self.purgeBuildOutput = purgeBuildOutput
    }

    enum CodingKeys: String, CodingKey {
        case version, scope, benchmarks, count, alpha
        case benchmarkTarget = "benchmark_target"
        case minEffectPct = "min_effect_pct"
        case maxRegressPct = "max_regress_pct"
        case timeoutSeconds = "timeout_seconds"
        case purgeBuildOutput = "purge_build_output"
        case benchmarkPackagePath = "benchmark_package_path"
    }

    /// Hand-written ONLY to make `purge_build_output` and
    /// `benchmark_package_path` optional-with-a-default.
    ///
    /// Every other key stays REQUIRED, and that asymmetry is the point rather
    /// than an oversight. A config missing `benchmarks` or `alpha` is a config
    /// this tool cannot act on and must refuse; a config missing
    /// `purge_build_output` is simply one written before the field existed,
    /// and it means exactly what it has always meant. Synthesizing this would
    /// have made the new key required and broken the second case, so it is
    /// written out -- and it is written out in full, rather than reached by a
    /// `try? container.decode`, so that a MALFORMED value (`purge_build_output:
    /// maybe`) still throws instead of being silently read as `false`. Absent
    /// and wrong are different, and only the first is acceptable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        scope = try c.decode([String].self, forKey: .scope)
        benchmarkTarget = try c.decode(String.self, forKey: .benchmarkTarget)
        benchmarks = try c.decode([String].self, forKey: .benchmarks)
        count = try c.decode(Int.self, forKey: .count)
        alpha = try c.decode(Double.self, forKey: .alpha)
        minEffectPct = try c.decode(Double.self, forKey: .minEffectPct)
        maxRegressPct = try c.decode(Double.self, forKey: .maxRegressPct)
        timeoutSeconds = try c.decode(Int.self, forKey: .timeoutSeconds)
        purgeBuildOutput = try c.decodeIfPresent(Bool.self, forKey: .purgeBuildOutput) ?? false
        // Written out in full for exactly the reason above it: `nil` here
        // means "the repository root", which is what every config written
        // before this key existed has always meant, while
        // `benchmark_package_path: [1, 2]` is a config the operator got wrong
        // and must be told about. `try?` would collapse those two into one.
        benchmarkPackagePath =
            try c.decodeIfPresent(String.self, forKey: .benchmarkPackagePath) ?? nil
    }

    /// Loads and decodes `autor3search.yaml` from `url`. Does not validate;
    /// call `validate()` separately once loaded.
    public static func load(_ url: URL) throws -> Config {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(Config.self, from: text)
    }

    /// Renders this config back to YAML, in the same key spelling `load`
    /// reads (`benchmark_target`, `min_effect_pct`, etc). Throws rather than
    /// swallowing an encode failure into an empty string: Task 15 writes
    /// this straight to `.autor3search/config.yaml`, and a silently empty
    /// config file would corrupt state far from the point of failure.
    public func serialized() throws -> String {
        try YAMLEncoder().encode(self)
    }
}
