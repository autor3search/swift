import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/GitExecConfigTests.swift
//
// THE FOURTEENTH AND FIFTEENTH, and the lesson between them.
//
// Round 5 denied `core.hooksPath` because a hook was the vector that had been
// found. `core.fsmonitor` is a SEPARATE code-execution config: git runs it on
// every `status`, `.git/config` is excluded from every content gate by design,
// and core config is shared with the linked worktree. An agent's fsmonitor
// therefore ran inside gate 7's own git calls and overwrote the baseline binary
// during the post-build `status` -- the window between the build and
// `MeasuredBinaryGuard`'s snapshot. Measured `rc 0 keep ratio 0.0501`.
//
// A denial list built from the last attack is always one attack behind, so this
// one is built from `git config`'s documentation for the installed version.
// What it CANNOT cover is the per-name families, and attacking one of those is
// how the fifteenth was found.

private func execRepo() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        git init -q . && git config user.name T && git config user.email t@e.com
        printf 'AAAAAAAAAA\\n' > f.txt && git add -A && git commit -q -m one
        """], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "\(r.stderr)")
    return dir
}

/// THE PREMISE AND THE FIX. `core.fsmonitor` runs a program on `status`, and
/// the harness's git invocations must not.
@Test func coreFsmonitorIsDeniedOnEveryHarnessInvocation() throws {
    let repo = try execRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let marker = repo.appendingPathComponent("fsmonitor.fired")
    let script = repo.appendingPathComponent("fsmon.sh")
    try "#!/bin/sh\necho fired >> \(marker.path)\nprintf '/\\\\0'\nexit 0\n"
        .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                           ["-c", "git config core.fsmonitor '\(script.path)'"],
                           cwd: repo, env: nil, timeout: 60)

    // THE PREMISE: a plain status really does run it.
    _ = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/git"), ["status", "--porcelain"],
                           cwd: repo, env: nil, timeout: 60)
    #expect(FileManager.default.fileExists(atPath: marker.path),
            "the premise fails: fsmonitor did not run even unprotected")
    try FileManager.default.removeItem(at: marker)

    // ...and every command `Git` runs does not. These are the five that were
    // measured to trigger it: status, status --ignored, ls-files, checkout and
    // add.
    let git = Git(repo: repo)
    _ = try? git.isClean()
    _ = try? git.status(includingIgnored: true)
    _ = try? git.run(["ls-files", "-v"])
    _ = try? git.run(["checkout", "--detach", "--force", "HEAD"])
    _ = try? git.run(["add", "--", "f.txt"])
    #expect(!FileManager.default.fileExists(atPath: marker.path),
            "core.fsmonitor ran inside a harness git invocation")
}

/// The denial list is spelled out here so that widening or narrowing it is a
/// deliberate edit to a test rather than a quiet change, and so the keys that
/// CANNOT be denied stay written down next to the ones that can.
@Test func theExecutionDenialListCoversTheDocumentedKeys() {
    // EXHAUSTIVE, NOT A SAMPLE. This pinned 17 of the 21 keys and therefore did
    // not do the one job it exists for: four could have been dropped silently,
    // and the count in the prose had already drifted from the code. Equality
    // against the whole set means adding or removing a key is a deliberate edit
    // in two places.
    let expected: Set<String> = [
        // Hooks, and the file-system monitor that is not a hook.
        "core.hooksPath", "core.fsmonitor",
        // Programs git runs for refs, transport and credentials.
        "core.alternateRefsCommand", "core.sshCommand", "core.gitProxy",
        "core.askPass", "credential.helper",
        // Programs git runs to show a human something. Never reached without a
        // tty, which is exactly why they are easy to forget.
        "core.pager", "core.editor", "sequence.editor",
        // External diff.
        "diff.external", "interactive.diffFilter",
        // Signing, reachable if a repository sets `commit.gpgSign`.
        "gpg.program", "gpg.openpgp.program", "gpg.x509.program", "gpg.ssh.program",
        "gpg.ssh.defaultKeyCommand",
        // Maintenance and server-side hooks ordinary commands can trigger.
        "gc.recentObjectsHook", "uploadpack.packObjectsHook",
        // Not execution themselves, but the out-of-tree door to the filter and
        // ignore machinery that is.
        "core.attributesFile", "core.excludesFile",
    ]
    #expect(expected.count == 21, "the pinned set is itself the wrong size")
    let denied = Set(Git.executionDenialKeys)
    #expect(denied == expected, """
        the denial list changed without this test changing. \
        added=\(denied.subtracting(expected).sorted()) \
        removed=\(expected.subtracting(denied).sorted())
        """)
    #expect(Git.executionDenialKeys.count == 21,
            "duplicate keys would make the set match while the list differs")

    // And the honest other half: per-name keys a `-c` cannot reach.
    #expect(Git.undeniableWildcardFamilies.contains("filter.<name>.clean"))
    #expect(Git.undeniableWildcardFamilies.contains("diff.<name>.textconv"))
}

/// THE FIFTEENTH. A `filter.<name>.clean` makes `git status` report a modified
/// file as unmodified, and `-c` cannot deny a per-name key. Content is hashed
/// against the commit's own blob ids instead, so no filter participates.
///
/// The size detail is load-bearing: git's `status` uses the index's stat size
/// as a fast path and calls a filtered file modified whenever the size differs,
/// without consulting the filter at all. A same-size edit is hidden completely;
/// a different-size one is not. That is why this test pads.
@Test func aCleanFilterCannotHideAnUncommittedEditFromTheContentCheck() throws {
    let repo = try execRepo()
    // The helper files live OUTSIDE the repository: untracked files inside it
    // would make `status --porcelain` non-empty for a reason that has nothing
    // to do with the filter, and the premise below would fail for the wrong
    // reason.
    let helpers = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: helpers)
    }
    let committed = helpers.appendingPathComponent("committed.txt")
    try "AAAAAAAAAA\n".write(to: committed, atomically: true, encoding: .utf8)
    let clean = helpers.appendingPathComponent("clean.sh")
    try "#!/bin/sh\ncat > /dev/null\ncat \(committed.path)\n"
        .write(to: clean, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clean.path)
    _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        printf 'f.txt filter=zz\\n' > .gitattributes
        git add -- .gitattributes && git commit -q -m attrs
        git config filter.zz.clean '\(clean.path)'
        """], cwd: repo, env: nil, timeout: 60)

    // Same byte length as the committed content, so git's size fast path does
    // not short-circuit and the clean filter is actually consulted.
    try "BBBBBBBBBB\n".write(to: repo.appendingPathComponent("f.txt"),
                             atomically: true, encoding: .utf8)
    let git = Git(repo: repo)
    #expect(try git.isClean(), """
        THE PREMISE: git itself must report this tree as clean, or the content check is not \
        being tested against anything
        """)

    let failure = EvalRunner.trackedContentFailure(git: git, repo: repo)
    #expect(failure?.reason == "dirty_working_tree")
    #expect(failure?.detail.contains("f.txt") == true, "\(failure?.detail ?? "nil")")
}

/// ...and an untouched repository passes it, or the check would refuse every
/// honest experiment.
@Test func theContentCheckPassesAnUntouchedRepository() throws {
    let repo = try execRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    #expect(EvalRunner.trackedContentFailure(git: Git(repo: repo), repo: repo) == nil)
}
