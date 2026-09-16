import Foundation

/// Persisted record of a run's baseline. Stored outside the repository under
/// test (see `StateHome`) so the agent cannot tamper with it.
///
/// Carries two commits that must never be conflated:
/// - `frozenCommit`: what the frozen files and the scope gate always compare
///   against. It NEVER advances. Moving the measurement point must never move
///   the success criteria.
/// - `measurementCommit`: what timings are measured against. It starts equal
///   to `frozenCommit` and ADVANCES to the candidate's commit after every
///   KEEP.
public struct BaselineRecord: Codable, Equatable, Sendable {
    public var tag: String
    public var frozenCommit: String
    public var measurementCommit: String
    public var configSHA256: String
    public var packageSwiftSHA256: String
    public var packageResolvedSHA256: String
    public var toolVersion: String

    public init(
        tag: String,
        frozenCommit: String,
        measurementCommit: String,
        configSHA256: String,
        packageSwiftSHA256: String,
        packageResolvedSHA256: String,
        toolVersion: String
    ) {
        self.tag = tag
        self.frozenCommit = frozenCommit
        self.measurementCommit = measurementCommit
        self.configSHA256 = configSHA256
        self.packageSwiftSHA256 = packageSwiftSHA256
        self.packageResolvedSHA256 = packageResolvedSHA256
        self.toolVersion = toolVersion
    }
}

extension BaselineRecord {
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func load(_ url: URL) throws -> BaselineRecord {
        try JSONDecoder().decode(BaselineRecord.self, from: Data(contentsOf: url))
    }
}
