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

    public init(
        version: Int,
        scope: [String],
        benchmarkTarget: String,
        benchmarks: [String],
        count: Int,
        alpha: Double,
        minEffectPct: Double,
        maxRegressPct: Double,
        timeoutSeconds: Int
    ) {
        self.version = version
        self.scope = scope
        self.benchmarkTarget = benchmarkTarget
        self.benchmarks = benchmarks
        self.count = count
        self.alpha = alpha
        self.minEffectPct = minEffectPct
        self.maxRegressPct = maxRegressPct
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case version, scope, benchmarks, count, alpha
        case benchmarkTarget = "benchmark_target"
        case minEffectPct = "min_effect_pct"
        case maxRegressPct = "max_regress_pct"
        case timeoutSeconds = "timeout_seconds"
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
