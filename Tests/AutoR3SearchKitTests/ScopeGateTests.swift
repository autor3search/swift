import Testing
@testable import AutoR3SearchKit

// MARK: - The six tests from the task brief, verbatim.

@Test func allowsPathsInsideScope() throws {
    try ScopeGate.check(changedPaths: ["Sources/Lib/A.swift"], scope: ["Sources/**"])
}

@Test func rejectsPathsOutsideScope() {
    #expect(throws: GateFailure.self) {
        try ScopeGate.check(changedPaths: ["Tools/script.sh"], scope: ["Sources/**"])
    }
}

@Test func rejectsPackageSwiftEvenWhenScopeWouldAllowIt() {
    // Regardless of scope: it is the dependency list AND the build-flag surface.
    #expect(throws: GateFailure.self) {
        try ScopeGate.check(changedPaths: ["Package.swift"], scope: ["**"])
    }
}

@Test func rejectsPackageResolvedEvenWhenScopeWouldAllowIt() {
    #expect(throws: GateFailure.self) {
        try ScopeGate.check(changedPaths: ["Package.resolved"], scope: ["**"])
    }
}

@Test func manifestRejectionNamesCompileFlagsInItsReason() {
    // The message must teach why, not just refuse.
    do {
        try ScopeGate.check(changedPaths: ["Package.swift"], scope: ["**"])
        Issue.record("expected a failure")
    } catch let f as GateFailure {
        #expect(f.detail.contains("unsafeFlags") || f.detail.contains("swiftSettings"))
    } catch { Issue.record("wrong error type") }
}

@Test func globMatchingHandlesNestedAndSingleLevel() {
    #expect(ScopeGate.matches("Sources/Lib/Deep/A.swift", glob: "Sources/**"))
    #expect(ScopeGate.matches("Sources/A.swift", glob: "Sources/*"))
    #expect(!ScopeGate.matches("Sources/Lib/A.swift", glob: "Sources/*"))
    #expect(!ScopeGate.matches("Tests/A.swift", glob: "Sources/**"))
}

// MARK: - Additional tests: not in the brief, added per task instructions.
//
// `changedPaths` (Task 10 fix) now returns genuine byte-exact paths from
// `git diff -z --no-renames --name-only`: real non-ASCII filenames, real
// leading/trailing spaces, and both sides of a rename. The brief's six tests
// do not exercise any of that against the glob matcher — these do.

/// A real non-ASCII filename (not the octal-escaped `"caf\303\251.swift"`
/// literal that a non-`-z` git invocation would have produced) must match an
/// ordinary `Sources/**` scope entry like any other file.
@Test func globMatchingHandlesNonASCIIFilenames() {
    #expect(ScopeGate.matches("Sources/café.swift", glob: "Sources/**"))
    try? ScopeGate.check(changedPaths: ["Sources/café.swift"], scope: ["Sources/**"])
}

/// Filenames with leading or trailing spaces are preserved byte-exact by
/// `changedPaths` (see `GitTests.changedPathsPreservesLeadingAndTrailingSpacesInFilenames`)
/// and must match the same way any other filename would.
@Test func globMatchingHandlesFilenamesWithLeadingAndTrailingSpaces() throws {
    #expect(ScopeGate.matches("Sources/ leading.swift", glob: "Sources/**"))
    #expect(ScopeGate.matches("Sources/trailing.swift ", glob: "Sources/**"))
    try ScopeGate.check(
        changedPaths: ["Sources/ leading.swift", "Sources/trailing.swift "],
        scope: ["Sources/**"])
}

/// `--no-renames` reports both the vacated old path and the new path as
/// separate entries in `changedPaths`. Both must be scope-checked
/// independently — a rename out of scope, or into scope, is still a real
/// content change at both locations.
@Test func globMatchingHandlesBothSidesOfARename() throws {
    try ScopeGate.check(
        changedPaths: ["Sources/Old.swift", "Sources/New.swift"],
        scope: ["Sources/**"])
    #expect(throws: GateFailure.self) {
        try ScopeGate.check(
            changedPaths: ["Sources/Old.swift", "Tools/New.sh"],
            scope: ["Sources/**"])
    }
}

// MARK: - The five design questions the task asked to think through.

/// Case sensitivity: the gate must be case-SENSITIVE on every platform, so
/// its behaviour does not depend on whether the host filesystem happens to
/// be case-insensitive (macOS APFS default) or case-sensitive (Linux).
/// `changedPaths` reports git's own case-exact record of the path, and this
/// matcher must not fold case to match it.
@Test func globMatchingIsCaseSensitive() {
    #expect(!ScopeGate.matches("sources/foo.swift", glob: "Sources/**"))
    #expect(!ScopeGate.matches("Sources/Foo.swift", glob: "Sources/foo.swift"))
    #expect(throws: GateFailure.self) {
        try ScopeGate.check(changedPaths: ["sources/foo.swift"], scope: ["Sources/**"])
    }
}

/// Unicode normalisation: Swift's default `String` comparison (used here)
/// compares by canonical equivalence, so an NFC-encoded and an NFD-encoded
/// spelling of the identical filename must be treated as the same path —
/// consistent with `FrozenSnapshot`'s `[String: String]` manifest, which
/// relies on the same default String equality elsewhere in this codebase.
@Test func globMatchingTreatsNFCAndNFDAsTheSamePath() {
    let nfc = "Sources/caf\u{00E9}.swift"       // é as a single precomposed scalar
    let nfd = "Sources/cafe\u{0301}.swift"      // e + combining acute accent
    #expect(nfc.unicodeScalars.count != nfd.unicodeScalars.count) // different scalar sequences
    #expect(nfc == nfd)                          // canonically equivalent under Swift String ==
    #expect(ScopeGate.matches(nfd, glob: "Sources/**"))           // matches via the /** prefix branch
    #expect(ScopeGate.matches(nfd, glob: nfc))                    // matches via the exact-equality branch
    #expect(ScopeGate.matches(nfc, glob: nfd))                    // and symmetrically
}

/// A bare directory name with no wildcard, e.g. `"Sources"`, matches only a
/// changed path literally named `"Sources"` — it does NOT recursively match
/// `"Sources/foo.swift"`. Decided and documented on `ScopeGate.matches`: a
/// glob matcher that silently treated a bare name as recursive would make
/// the gate's actual reach wider than its author is likely to expect, which
/// is the wrong direction to be wrong in for a security gate.
@Test func bareDirectoryNameDoesNotMatchItsContents() {
    #expect(!ScopeGate.matches("Sources/foo.swift", glob: "Sources"))
    #expect(ScopeGate.matches("Sources", glob: "Sources"))
    #expect(throws: GateFailure.self) {
        try ScopeGate.check(changedPaths: ["Sources/foo.swift"], scope: ["Sources"])
    }
}

/// An empty changed-path list has nothing to reject in either the manifest
/// check or the scope loop, so it must pass trivially — a no-op change is
/// not a scope violation, and this must never crash on an empty array.
@Test func emptyChangedPathsPassesTrivially() throws {
    try ScopeGate.check(changedPaths: [], scope: ["Sources/**"])
    try ScopeGate.check(changedPaths: [], scope: [])
}
