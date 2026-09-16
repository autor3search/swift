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

    /// EVERY manifest-or-manifest-equivalent file in the repository at
    /// `frozenCommit`, relative path -> SHA-256 of its bytes. "Manifest" here
    /// is exactly `ScopeGate.isManifestPath` -- one definition, shared with
    /// the scope gate, so the two can never drift apart.
    ///
    /// `packageSwiftSHA256` and `packageResolvedSHA256` cover only the ROOT
    /// manifests. `ScopeGate` catches a NESTED one (`Sub/Package.swift`), a
    /// version-specific one (`Package@swift-6.0.swift`) and anything under
    /// `.swiftpm/` -- but only BY PATH, and `git update-index
    /// --assume-unchanged` defeats every path-based check. So without this,
    /// the `-Ounchecked` bypass closed for the root manifest stayed wide open
    /// for a nested one, and the project's claim that manifest changes are
    /// "rejected outright regardless of scope" was true only at the root.
    ///
    /// OPTIONAL, and deliberately not defaulted to `[:]` at the point of use.
    /// A record written before this field existed decodes as `nil`, and `nil`
    /// means "this baseline has no inventory", which `eval` REFUSES -- it does
    /// not mean "the inventory is empty", which would silently restore the
    /// hole for exactly the runs that predate the fix. See
    /// `EvalRunner.manifestIntegrityFailure`.
    public var manifestSHA256: [String: String]?

    public init(
        tag: String,
        frozenCommit: String,
        measurementCommit: String,
        configSHA256: String,
        packageSwiftSHA256: String,
        packageResolvedSHA256: String,
        toolVersion: String,
        manifestSHA256: [String: String]? = nil
    ) {
        self.manifestSHA256 = manifestSHA256
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
