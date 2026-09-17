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

    /// EVERY file in the repository that the config's `scope` does NOT cover,
    /// relative path -> SHA-256 of its bytes (or, for a symbolic link, its
    /// destination; see `BaselineRunner.treeEntryDigest`). `.git/`, `.build/`
    /// and the harness's own outputs are excluded.
    ///
    /// WHY IT IS NOT ENOUGH TO ENFORCE `scope` THROUGH GIT. Gate 1 asks `git
    /// diff --name-only frozenCommit HEAD` which paths changed, and gate 2b
    /// asks `git status` whether anything is uncommitted. Both answers come
    /// out of git, and the agent owns git's view of its own repository: `git
    /// update-index --assume-unchanged <an out-of-scope helper>` removes the
    /// file from both answers while `swift build` keeps compiling it.
    /// Demonstrated on the demo package by setting a benchmark helper's
    /// `repeatCount` from 1750 to 1: `eval rc=0, ratio 0.000742`, with no gate
    /// raising a word. `manifestSHA256` closed that door for MANIFESTS; this
    /// is the general form, and it is also what catches a manifest under a
    /// case-variant spelling (`PACKAGE@SWIFT-6.4.SWIFT`) that
    /// `ScopeGate.isManifestPath` -- deliberately case-sensitive -- does not
    /// recognise, but a case-insensitive APFS hands to SwiftPM anyway.
    ///
    /// OPTIONAL for the same reason `manifestSHA256` is, with the same ruling:
    /// a record written before this field existed decodes as `nil`, and `nil`
    /// means "this baseline has no inventory", which `eval` REFUSES
    /// (`baseline_predates_tree_inventory`). It must never be read as "the
    /// inventory is empty", which would silently restore the hole for exactly
    /// the runs that predate the fix.
    public var treeSHA256: [String: String]?

    /// Every file an ignore rule was hiding from `git status` when the
    /// baseline was taken, relative path -> digest. `.build/` and the
    /// harness's own outputs are excluded.
    ///
    /// Gate 2b refuses on an ignored file that was ADDED, MODIFIED or REMOVED
    /// since the freeze, and passes one that is unchanged. The distinction is
    /// the whole design:
    ///
    /// - An ignored file already present at baseline is part of the honest
    ///   starting point. `frozenCommit` was taken with it there, the pinned
    ///   worktree's build saw the same repository, and it gives neither side
    ///   an advantage. Refusing it -- as the first version of this gate did --
    ///   makes `eval` fail on `autor3search-swift`'s own repository (which
    ///   ignores `docs/` and `.superpowers/`, both present) and on most real
    ///   repositories, which ignore `.DS_Store`, editor state, vendored
    ///   directories or pre-existing generated sources.
    /// - An ignored file that appears AFTER the freeze is the attack. The
    ///   pinned measurement worktree is a checkout of a COMMIT and can never
    ///   contain it, so it exists on the candidate side only and manufactures
    ///   a win on every later eval -- and `git add -A` will not commit it and
    ///   `git reset --hard` will not remove it, so it does not wash out
    ///   between experiments.
    ///
    /// Written by the same `baseline` that writes `treeSHA256`, so a record
    /// carrying one always carries the other; `nil` here means the same thing
    /// `nil` there does and is refused under the same reason string rather
    /// than adding a second one to the `--json` contract.
    public var ignoredSHA256: [String: String]?

    /// Every file under `.build/checkouts` that SwiftPM will COMPILE, as a
    /// path relative to that directory -> digest. Each checkout's own `.git`
    /// is excluded.
    ///
    /// `.build/` is exempt from the out-of-scope inventory and from the
    /// dirty-tree gate, and git collapses it to a single `!!` record -- but
    /// `.build/checkouts` is not build output. It is SOURCE, it is inside the
    /// repository under test, and SwiftPM does not re-verify it once a
    /// checkout exists. Editing a dependency's benchmark timer there, with a
    /// comment-only commit, measured `rc 0, keep, ratio 0.0099977`. The
    /// benchmark package's `BenchmarkPlugin` also lives there and is a
    /// build-tool plugin, so the same edit primitive is arbitrary code
    /// execution during the build.
    ///
    /// A whole dependency MISSING is not a refusal -- SwiftPM re-clones it
    /// from the revision `Package.resolved` pins, and that file's own bytes
    /// are hashed by gate 2a, so the clone is trustworthy. A dependency that
    /// is PRESENT must match exactly, file set included.
    ///
    /// Written by the same `baseline` that writes `treeSHA256` and
    /// `ignoredSHA256`, so a record carrying one carries all three; `nil` is
    /// refused under the same reason string rather than adding another to the
    /// `--json` contract.
    public var checkoutSHA256: [String: String]?

    public init(
        tag: String,
        frozenCommit: String,
        measurementCommit: String,
        configSHA256: String,
        packageSwiftSHA256: String,
        packageResolvedSHA256: String,
        toolVersion: String,
        manifestSHA256: [String: String]? = nil,
        treeSHA256: [String: String]? = nil,
        ignoredSHA256: [String: String]? = nil,
        checkoutSHA256: [String: String]? = nil
    ) {
        self.manifestSHA256 = manifestSHA256
        self.treeSHA256 = treeSHA256
        self.ignoredSHA256 = ignoredSHA256
        self.checkoutSHA256 = checkoutSHA256
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
