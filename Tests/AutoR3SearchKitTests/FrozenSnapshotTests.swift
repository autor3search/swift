import Testing
import Foundation
@testable import AutoR3SearchKit

private func scratch() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func restoreErasesAgentEditsToFrozenFiles() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    let file = tests.appendingPathComponent("T.swift")
    try "assert(real)".write(to: file, atomically: true, encoding: .utf8)

    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)
    try "assert(true) // weakened".write(to: file, atomically: true, encoding: .utf8)
    try snap.restore(repo: repo, from: store)

    #expect(try String(contentsOf: file, encoding: .utf8) == "assert(real)")
}

@Test func newFilesInFrozenDirectoriesAreDetected() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "a".write(to: tests.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    // SwiftPM compiles a new file in an existing test target without any
    // Package.swift edit - verified in spec.md 2.4. So this gate is load-bearing.
    try "easy".write(to: tests.appendingPathComponent("Sneaky.swift"), atomically: true, encoding: .utf8)
    #expect(try snap.newFiles(repo: repo, directories: ["Tests/DemoTests"]) == ["Tests/DemoTests/Sneaky.swift"])
}

@Test func snapshotRefusesToFreezeASymlink() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: tests.appendingPathComponent("T.swift"),
        withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    #expect(throws: FrozenError.self) {
        try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)
    }
}

@Test func restoreRefusesToWriteThroughASymlinkPlantedLater() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    let file = tests.appendingPathComponent("T.swift")
    try "assert(real)".write(to: file, atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    // The agent replaces the frozen file with a link to something outside the repo.
    let victim = try scratch().appendingPathComponent("victim.txt")
    try "do not overwrite me".write(to: victim, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)

    #expect(throws: FrozenError.self) { try snap.restore(repo: repo, from: store) }
    #expect(try String(contentsOf: victim, encoding: .utf8) == "do not overwrite me",
            "restore wrote through the symlink: arbitrary file overwrite")
}

// MARK: - Adversarial cases beyond the four above

/// A check on the final path component alone is not enough. The kernel
/// resolves `Tests` before it looks at `T.swift`, so swapping the *directory*
/// for a link leaves the leaf looking like an ordinary regular file while the
/// write lands wherever the link points.
@Test func restoreRefusesWhenAnAncestorDirectoryBecameASymlink() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "assert(real)".write(to: tests.appendingPathComponent("T.swift"),
                             atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    // The agent swaps the whole frozen directory for a link to a directory
    // outside the repository, holding a file of the same name.
    let outside = try scratch()
    let victim = outside.appendingPathComponent("T.swift")
    try "do not overwrite me".write(to: victim, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: tests)
    try FileManager.default.createSymbolicLink(at: tests, withDestinationURL: outside)

    #expect(throws: FrozenError.symlinkInPath("Tests/DemoTests")) {
        try snap.restore(repo: repo, from: store)
    }
    #expect(try String(contentsOf: victim, encoding: .utf8) == "do not overwrite me",
            "restore wrote through a symlinked parent directory: arbitrary file overwrite")
}

/// The same swap seen from the other side: a frozen directory that is a link
/// must not be walked. Foundation's enumerator returns nothing at all for a
/// symlinked base, so silently continuing would produce an empty manifest —
/// a freeze that protects nothing, reported as success.
@Test func snapshotRefusesAFrozenDirectoryThatIsASymlink() throws {
    let repo = try scratch(), store = try scratch()
    let outside = try scratch()
    try "assert(real)".write(to: outside.appendingPathComponent("T.swift"),
                             atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("Tests"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: repo.appendingPathComponent("Tests/DemoTests"), withDestinationURL: outside)

    #expect(throws: FrozenError.symlinkInPath("Tests/DemoTests")) {
        try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)
    }
}

/// A hard link is indistinguishable from the original by `lstat` type alone:
/// both are regular files, and only the link count gives it away. The atomic
/// write would sever the link rather than rewrite the shared inode, so this
/// guard is an integrity signal rather than an overwrite stop: a frozen file
/// that has grown a second name is not the file that was frozen.
@Test func restoreRefusesToWriteThroughAHardLink() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    let file = tests.appendingPathComponent("T.swift")
    try "assert(real)".write(to: file, atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    let victim = try scratch().appendingPathComponent("victim.txt")
    try "do not overwrite me".write(to: victim, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.linkItem(at: victim, to: file)

    #expect(throws: FrozenError.hardLinkAtRestore("Tests/DemoTests/T.swift")) {
        try snap.restore(repo: repo, from: store)
    }
    #expect(try String(contentsOf: victim, encoding: .utf8) == "do not overwrite me",
            "restore wrote through a hard link: arbitrary file overwrite")
}

/// The manifest is read back from disk on a later invocation, so its keys are
/// the direct source of the paths `restore` writes to and are not trusted.
@Test func restoreRefusesManifestPathsThatLeaveTheRepository() throws {
    let repo = try scratch(), store = try scratch()
    for bad in ["../victim.txt", "/etc/hosts", "Tests/../../victim.txt",
                "~/.ssh/authorized_keys", "Tests/./T.swift", "Tests//T.swift", ""] {
        #expect(throws: FrozenError.escapingPath(bad), "accepted escaping path \(bad)") {
            try FrozenSnapshot(manifest: [bad: "0"]).restore(repo: repo, from: store)
        }
    }
}

@Test func plainRelativePathsAreAccepted() throws {
    #expect(try FrozenSnapshot.checked(relative: "Tests/DemoTests/T.swift")
            == "Tests/DemoTests/T.swift")
    #expect(try FrozenSnapshot.checked(relative: "Tests/DemoTests/") == "Tests/DemoTests")
    #expect(try FrozenSnapshot.checked(relative: "..hidden/T.swift") == "..hidden/T.swift")
}

/// Task 17 runs in a different process from Task 16, so "is this file new
/// since baseline?" has to be answerable from what baseline wrote down.
@Test func manifestSurvivesASeparateProcessThroughSaveAndLoad() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "a".write(to: tests.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    let url = try scratch().appendingPathComponent("frozen-manifest.json")
    try snap.save(to: url)
    let reloaded = try FrozenSnapshot.load(url)
    #expect(reloaded == snap)
    #expect(reloaded.manifest["Tests/DemoTests/T.swift"]
            // SHA-256 of "a"
            == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
    // The scope crosses the process boundary with the manifest, or the
    // question "new since baseline?" has no fixed frame of reference.
    #expect(reloaded.directories == ["Tests/DemoTests"])

    // The reloaded manifest, not the store, is what answers the question.
    try "easy".write(to: tests.appendingPathComponent("Sneaky.swift"),
                     atomically: true, encoding: .utf8)
    #expect(try reloaded.newFiles(repo: repo) == ["Tests/DemoTests/Sneaky.swift"])
    #expect(try reloaded.newFiles(repo: repo, directories: ["Tests/DemoTests"])
            == ["Tests/DemoTests/Sneaky.swift"])
}

/// The dangerous case is a NARROWER list than baseline used: the dropped
/// directories are never scanned, so nothing in them is ever reported as new
/// and the scope gate shrinks with no symptom at all.
@Test func newFilesRefusesAScopeThatDisagreesWithBaseline() throws {
    let repo = try scratch(), store = try scratch()
    for dir in ["Tests/DemoTests", "Benchmarks"] {
        let d = repo.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "a".write(to: d.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
    }
    let snap = try FrozenSnapshot.snapshot(
        repo: repo, directories: ["Tests/DemoTests", "Benchmarks"], into: store)
    #expect(snap.directories == ["Benchmarks", "Tests/DemoTests"])

    // Narrower: the silent-shrink case.
    #expect(throws: FrozenError.directoriesMismatch(
        recorded: ["Benchmarks", "Tests/DemoTests"], requested: ["Tests/DemoTests"])) {
        try snap.newFiles(repo: repo, directories: ["Tests/DemoTests"])
    }
    // Wider is refused too: it would compare against a scope never frozen.
    #expect(throws: FrozenError.self) {
        try snap.newFiles(repo: repo, directories: ["Tests/DemoTests", "Benchmarks", "Sources"])
    }
    // Spelling and ordering are not scope, and must not be mistaken for it.
    #expect(try snap.newFiles(repo: repo, directories: ["Benchmarks/", "Tests/DemoTests"]) == [])
}

@Test func loadRejectsAManifestWithAnEscapingPath() throws {
    let url = try scratch().appendingPathComponent("frozen-manifest.json")
    try Data(#"{"directories":["Tests"],"manifest":{"../victim.txt":"0"}}"#.utf8).write(to: url)
    #expect(throws: FrozenError.escapingPath("../victim.txt")) { try FrozenSnapshot.load(url) }
}

@Test func loadRejectsARecordedDirectoryThatEscapesTheRepository() throws {
    let url = try scratch().appendingPathComponent("frozen-manifest.json")
    try Data(#"{"directories":["../elsewhere"],"manifest":{}}"#.utf8).write(to: url)
    #expect(throws: FrozenError.escapingPath("../elsewhere")) { try FrozenSnapshot.load(url) }
}

/// A symlink planted after baseline is reported by the scope gate as well as
/// refused by restore, so an operator reading the run log sees it either way.
@Test func newFilesReportsAPlantedSymlink() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try "a".write(to: tests.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    try FileManager.default.createSymbolicLink(
        at: tests.appendingPathComponent("Link.swift"),
        withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    #expect(try snap.newFiles(repo: repo, directories: ["Tests/DemoTests"])
            == ["Tests/DemoTests/Link.swift"])
}

@Test func restoreRebuildsFrozenFilesTheAgentDeleted() throws {
    let repo = try scratch(), store = try scratch()
    let tests = repo.appendingPathComponent("Tests/DemoTests")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    let deep = tests.appendingPathComponent("Deep")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    try "assert(real)".write(to: deep.appendingPathComponent("T.swift"),
                             atomically: true, encoding: .utf8)
    let snap = try FrozenSnapshot.snapshot(repo: repo, directories: ["Tests/DemoTests"], into: store)

    try FileManager.default.removeItem(at: tests)
    try snap.restore(repo: repo, from: store)
    #expect(try String(contentsOf: deep.appendingPathComponent("T.swift"), encoding: .utf8)
            == "assert(real)")
}
