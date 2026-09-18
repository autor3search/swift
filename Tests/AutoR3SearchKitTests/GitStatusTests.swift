import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/GitStatusTests.swift
//
// `Git.status(includingIgnored:)`. Kept in its own file rather than appended to
// GitTests.swift so the parsing rules and the bypass they close stay together.

private func statusRepo() throws -> (URL, Git) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = """
    git init -q .
    git config user.name  "Test"
    git config user.email "test@example.com"
    echo one > a.txt
    git add -A && git commit -q -m one
    """
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script],
                               cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "fixture repo setup failed: \(r.stderr)")
    return (dir, Git(repo: dir))
}

/// `git status --porcelain` omits ignored files, and that omission was a live
/// bypass of the dirty-tree gate: an agent that controls an ignore rule can
/// leave a source file on disk that `swift build` compiles and `git status`
/// reports as nothing. `.gitignore` is committable but, inside an in-scope
/// directory, is neither out of scope nor a manifest -- so gate 1 passes it.
@Test func statusReportsIgnoredFilesOnlyWhenAsked() throws {
    let (dir, git) = try statusRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    try ".build/\n*.gen.swift\n".write(to: dir.appendingPathComponent(".gitignore"),
                                       atomically: true, encoding: .utf8)
    let commit = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "git add -- .gitignore && git commit -q -m ignore"],
        cwd: dir, env: nil, timeout: 60)
    #expect(commit.exitCode == 0, "\(commit.stderr)")

    try "planted".write(to: dir.appendingPathComponent("Boost.gen.swift"),
                        atomically: true, encoding: .utf8)

    // THE PREMISE, asserted rather than assumed.
    #expect(try git.isClean(), "the ignored file must be invisible without --ignored")
    #expect(try git.status(includingIgnored: false).isEmpty)

    let withIgnored = try git.status(includingIgnored: true)
    let planted = withIgnored.first { $0.path == "Boost.gen.swift" }
    #expect(planted != nil, "got \(withIgnored)")
    #expect(planted?.isIgnored == true)
    #expect(planted?.code == "!!")
}

/// `.git/info/exclude` is the same hole with no repository file to review, to
/// commit, or for any path-based gate to inspect. Neither of the
/// previously-closed index-flag bypasses (`--assume-unchanged`,
/// `--skip-worktree`) covers it, so it needs its own binding.
@Test func statusSeesFilesHiddenByGitInfoExclude() throws {
    let (dir, git) = try statusRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let exclude = dir.appendingPathComponent(".git/info/exclude")
    try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "hidden.swift\n".write(to: exclude, atomically: true, encoding: .utf8)
    try "planted".write(to: dir.appendingPathComponent("hidden.swift"),
                        atomically: true, encoding: .utf8)

    #expect(try git.isClean(), "the premise: .git/info/exclude hides it from a plain status")
    let entries = try git.status(includingIgnored: true)
    #expect(entries.contains { $0.path == "hidden.swift" && $0.isIgnored }, "got \(entries)")
}

/// Three parsing details a newline-splitting parser gets wrong, each of which
/// would drop or mangle a refusal: a rename emits its ORIGINAL path as a
/// second, bare NUL record; a wholly-ignored directory is COLLAPSED to one
/// `dir/` entry (which is why the harness-output allowlist has to match a
/// trailing slash); and a filename containing a space survives intact only
/// because `-z` turns off `core.quotePath`.
@Test func statusParsesRenamesCollapsedDirectoriesAndSpacedNames() throws {
    let (dir, git) = try statusRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    try "ignored/\n".write(to: dir.appendingPathComponent(".gitignore"),
                           atomically: true, encoding: .utf8)
    try "with space".write(to: dir.appendingPathComponent("a space.txt"),
                           atomically: true, encoding: .utf8)
    let prep = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "git add -- .gitignore 'a space.txt' && git commit -q -m two && git mv a.txt b.txt"],
        cwd: dir, env: nil, timeout: 60)
    #expect(prep.exitCode == 0, "\(prep.stderr)")

    try FileManager.default.createDirectory(at: dir.appendingPathComponent("ignored"),
                                            withIntermediateDirectories: true)
    try "x".write(to: dir.appendingPathComponent("ignored/x.txt"), atomically: true, encoding: .utf8)
    try "touched".write(to: dir.appendingPathComponent("a space.txt"),
                        atomically: true, encoding: .utf8)

    let entries = try git.status(includingIgnored: true)
    let rename = entries.first { $0.path == "b.txt" }
    #expect(rename?.originalPath == "a.txt",
            "the rename's source is a bare follow-on record, not an entry of its own: \(entries)")
    #expect(entries.contains { $0.path == "ignored/" && $0.isIgnored },
            "a wholly-ignored directory collapses to one record: \(entries)")
    #expect(entries.contains { $0.path == "a space.txt" },
            "-z must keep an unquoted, byte-exact path: \(entries)")
}
