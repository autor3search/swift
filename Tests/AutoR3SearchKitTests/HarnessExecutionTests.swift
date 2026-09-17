import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/HarnessExecutionTests.swift
//
// THE ROOT CAUSE, ONE STEP ON. Every earlier bypass answered "does the COMPILER
// read it?". These answer "does the HARNESS RUN it?" -- and both questions have
// to be asked of every exempt region now.
//
//   - `.git/` is exempt from every inventory and git never reports it. It also
//     holds HOOKS, which are code, and the hook directory is SHARED with every
//     linked worktree -- so the harness's own `checkout --force` inside
//     `restoreToPin` runs the agent's script.
//   - The ENVIRONMENT is adversary-controlled input in any deployment where the
//     agent invokes `eval`, and it reached git (`GIT_CONFIG_COUNT` can set
//     `core.hooksPath` with nothing written under `.git/` at all) and the Swift
//     toolchain (`SWIFT_EXEC`, `DYLD_INSERT_LIBRARIES`, ...) unfiltered.

private func sh(_ script: String, in dir: URL) throws {
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script],
                               cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "\(script): \(r.stderr)")
}

private func scratchRepo() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try sh("""
        git init -q . && git config user.name T && git config user.email t@e.com
        printf 'original\\n' > f.txt && git add -A && git commit -q -m one
        """, in: dir)
    return dir
}

/// Plants a `post-checkout` hook that writes a marker, and returns the marker
/// path. The marker is the evidence: a rebuild cannot create one.
private func plantHook(_ repo: URL) throws -> URL {
    let marker = repo.appendingPathComponent("hook-ran.marker")
    let hooks = repo.appendingPathComponent(".git/hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let hook = hooks.appendingPathComponent("post-checkout")
    try "#!/bin/sh\necho ran > \(marker.path)\nexit 0\n"
        .write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    return marker
}

// =========================================================================
// MARK: - Hooks are code the harness runs
// =========================================================================

/// THE PREMISE AND THE FIX IN ONE TEST: a plain `git checkout --force` runs the
/// hook, and every invocation `Git` makes does not.
@Test func gitHooksAreDeniedOnEveryHarnessInvocation() throws {
    let repo = try scratchRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let marker = try plantHook(repo)

    // THE PREMISE, asserted rather than assumed.
    try sh("git checkout --detach --force HEAD", in: repo)
    #expect(FileManager.default.fileExists(atPath: marker.path),
            "the premise fails: the hook did not run even unprotected")
    try FileManager.default.removeItem(at: marker)

    // ...and through `Git`, which prefixes `-c core.hooksPath=/dev/null`.
    let git = Git(repo: repo)
    try git.run(["checkout", "--detach", "--force", "HEAD"])
    #expect(!FileManager.default.fileExists(atPath: marker.path),
            "a hook ran inside a harness git invocation")

    // The same for the calls that actually matter during an eval.
    _ = try? git.status(includingIgnored: true)
    _ = try? git.head()
    try? Worktree.repoint(git: git, at: repo, to: try git.head())
    #expect(!FileManager.default.fileExists(atPath: marker.path),
            "a hook ran during status/head/repoint")
}

/// `core.hooksPath` can come from the ENVIRONMENT, with nothing written under
/// `.git/` at all -- so deleting or inspecting `.git/hooks` would not have
/// fixed this. A `-c` on the command line outranks it.
@Test func hooksInjectedThroughTheEnvironmentAreDeniedToo() throws {
    let repo = try scratchRepo()
    let hooks = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: hooks)
    }
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let marker = repo.appendingPathComponent("env-hook.marker")
    let hook = hooks.appendingPathComponent("post-checkout")
    try "#!/bin/sh\necho ran > \(marker.path)\nexit 0\n"
        .write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

    // Nothing at all under .git/hooks.
    #expect(!FileManager.default.fileExists(
        atPath: repo.appendingPathComponent(".git/hooks/post-checkout").path))

    // THE PREMISE: the environment alone is enough, without `-c`.
    let injected = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
                    "GIT_CONFIG_VALUE_0": hooks.path, "PATH": "/usr/bin:/bin"]
    _ = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/git"),
                           ["checkout", "--detach", "--force", "HEAD"],
                           cwd: repo, env: injected, timeout: 60)
    #expect(FileManager.default.fileExists(atPath: marker.path),
            "the premise fails: GIT_CONFIG_COUNT did not install the hook")
    try FileManager.default.removeItem(at: marker)

    // ...and `-c core.hooksPath=/dev/null` beats it, which is what `Git` sends.
    _ = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/git"),
                           ["-c", "core.hooksPath=/dev/null",
                            "checkout", "--detach", "--force", "HEAD"],
                           cwd: repo, env: injected, timeout: 60)
    #expect(!FileManager.default.fileExists(atPath: marker.path),
            "a command-line -c must outrank GIT_CONFIG_* from the environment")
}

/// The post-condition must be sampled AFTER the last thing that could change
/// it. The hook beat the previous version by re-flagging during the checkout,
/// so the sample taken before it was empty and the warning never fired.
@Test func restoreToPinResamplesIndexFlagsAfterTheCheckout() throws {
    let repo = try scratchRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let git = Git(repo: repo)
    let head = try git.head()

    // A hook that re-flags and re-tampers, exactly as the live attack did.
    let hooks = repo.appendingPathComponent(".git/hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let hook = hooks.appendingPathComponent("post-checkout")
    try """
        #!/bin/sh
        git update-index --skip-worktree f.txt 2>/dev/null
        echo TAMPERED > f.txt
        exit 0
        """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

    // With hooks denied it never gets the chance, and the restore is clean.
    let flagged = try Worktree.restoreToPin(git: git, at: repo, to: head)
    #expect(flagged.isEmpty, "nothing was flagged before the checkout: \(flagged)")
    #expect(try String(contentsOf: repo.appendingPathComponent("f.txt"), encoding: .utf8)
            == "original\n", "the hook re-tampered after the restore")
    #expect(try Worktree.indexFlaggedPaths(at: repo).isEmpty)
    #expect(try Worktree.contentMismatches(at: repo, commit: head).isEmpty)
}

// =========================================================================
// MARK: - Content, not `git status`
// =========================================================================

/// `git status` can be made to lie about CONTENT, not merely about index flags.
/// A `.gitattributes` entry plus a `filter.<driver>` in `.git/config` -- both
/// agent-writable -- runs a smudge filter on checkout and a clean filter when
/// git compares the result back, so the worktree holds one thing and git
/// reports another. Denying hooks does nothing about it: different code.
///
/// Measured directly on a standalone repository:
/// worktree `count = 17500`, commit `count = 1750`, `git status --porcelain`
/// empty, `hash-object --no-filters f0b02a86...` against blob `cc57109a...`.
@Test func contentMismatchesSeesWhatGitStatusIsFooledAbout() throws {
    let repo = try scratchRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    try sh("""
        printf 'count = 1750\\n' > helper.txt
        printf 'helper.txt filter=evil\\n' > .gitattributes
        git add -A && git commit -q -m two
        git config filter.evil.smudge 'sed s/1750/17500/'
        git config filter.evil.clean  'sed s/17500/1750/'
        """, in: repo)
    let git = Git(repo: repo)
    let head = try git.head()
    #expect(try Worktree.contentMismatches(at: repo, commit: head).isEmpty,
            "an untouched tree must pass, or the check is useless")

    // THE MECHANISM, and it needs git's own checkout to complete: the agent
    // dirties the file, the harness's restore force-checks-it-out, the SMUDGE
    // filter rewrites what lands on disk, and git records the stat of what it
    // just wrote -- so `status` afterwards trusts that cached stat and never
    // re-compares the content at all.
    try "count = 999\n".write(to: repo.appendingPathComponent("helper.txt"),
                              atomically: true, encoding: .utf8)
    try git.run(["checkout", "--detach", "--force", head])
    #expect(try String(contentsOf: repo.appendingPathComponent("helper.txt"), encoding: .utf8)
            == "count = 17500\n",
            "the premise fails: the smudge filter did not run during the checkout")

    let mismatches = try Worktree.contentMismatches(at: repo, commit: head)
    #expect(mismatches.contains { $0.hasPrefix("helper.txt") },
            "the content check must see it: \(mismatches)")
    #expect(try git.isClean(), """
        THE PREMISE: git itself reports the tree as clean, which is why `verify` \
        cannot be the last word
        """)
}

/// The blob identifier is git's own, computed without running git -- so the
/// comparison cannot be affected by any filter, attribute or configuration.
@Test func blobIdentifierMatchesGitsOwnHashObject() throws {
    let repo = try scratchRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    for body in ["", "original\n", "a longer body with \u{00e9} and a NUL-free tail\n"] {
        let url = repo.appendingPathComponent("probe.bin")
        try Data(body.utf8).write(to: url)
        let mine = Worktree.blobIdentifier(Data(body.utf8))
        let theirs = try Git(repo: repo).run(["hash-object", "--no-filters", "probe.bin"])
        #expect(mine == theirs, "blob id for \(body.debugDescription)")
    }
}

/// A missing file, and a re-aimed symbolic link, are both mismatches: git
/// stores a link's TARGET as the blob, so changing where it points changes the
/// content.
@Test func contentMismatchesReportsMissingFilesAndRetargetedLinks() throws {
    let repo = try scratchRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    try sh("""
        ln -s /etc/hosts link.txt
        git add -A && git commit -q -m two
        """, in: repo)
    let git = Git(repo: repo)
    let head = try git.head()
    #expect(try Worktree.contentMismatches(at: repo, commit: head).isEmpty)

    try FileManager.default.removeItem(at: repo.appendingPathComponent("link.txt"))
    try FileManager.default.createSymbolicLink(
        at: repo.appendingPathComponent("link.txt"),
        withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    #expect(try Worktree.contentMismatches(at: repo, commit: head)
            .contains { $0.hasPrefix("link.txt") }, "a re-aimed link changes the blob")

    try FileManager.default.removeItem(at: repo.appendingPathComponent("f.txt"))
    #expect(try Worktree.contentMismatches(at: repo, commit: head)
            .contains { $0.contains("f.txt") && $0.contains("missing") })
}

// =========================================================================
// MARK: - The environment the harness hands to its tools
// =========================================================================

/// An ALLOWLIST, not a denylist. A denylist has to enumerate every variable of
/// two separately-evolving tools -- git alone added `GIT_CONFIG_COUNT` in 2.31
/// -- and being one release behind is a hole. An allowlist is wrong in the safe
/// direction: a tool that cannot find something fails loudly.
@Test func theToolEnvironmentIsAnAllowlistAndDropsEveryInjectionVector() {
    let hostile = [
        // git's configuration and storage redirection
        "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": "/tmp/evil", "GIT_CONFIG_GLOBAL": "/tmp/g",
        "GIT_CONFIG_SYSTEM": "/tmp/s", "GIT_DIR": "/tmp/d", "GIT_WORK_TREE": "/tmp/w",
        "GIT_INDEX_FILE": "/tmp/i", "GIT_OBJECT_DIRECTORY": "/tmp/o",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": "/tmp/a", "GIT_ATTR_NOSYSTEM": "1",
        "GIT_NOGLOB_PATHSPECS": "1", "GIT_SSH_COMMAND": "/tmp/ssh",
        // toolchain selection and code injection
        "SWIFT_EXEC": "/tmp/fake-swiftc", "SWIFTPM_CUSTOM_BUILD": "1",
        "SWIFT_DETERMINISTIC_HASHING": "1", "TOOLCHAINS": "org.evil",
        "DEVELOPER_DIR": "/tmp/xcode", "SDKROOT": "/tmp/sdk",
        "CC": "/tmp/cc", "CXX": "/tmp/cxx", "CFLAGS": "-O0", "LDFLAGS": "-L/tmp",
        "DYLD_INSERT_LIBRARIES": "/tmp/skew.dylib", "DYLD_LIBRARY_PATH": "/tmp",
        "LD_LIBRARY_PATH": "/tmp", "MACOSX_DEPLOYMENT_TARGET": "10.0",
        // ...and the ones that must survive
        "PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "TMPDIR": "/var/tmp/",
        "LANG": "en_US.UTF-8", "TERM": "xterm",
    ]
    let filtered = SanitizedEnvironment.filtered(hostile)
    #expect(filtered == ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone",
                         "TMPDIR": "/var/tmp/", "LANG": "en_US.UTF-8", "TERM": "xterm"],
            "got \(filtered)")
    // Nothing whose name merely LOOKS safe gets in by prefix.
    #expect(SanitizedEnvironment.filtered(["PATHOLOGICAL": "x", "HOMEBREW_PREFIX": "y"]).isEmpty)
}

/// Every name in the allowlist is there for a stated reason, and the set is
/// small enough to read. Pinned so that widening it is a deliberate edit to a
/// test rather than a quiet addition.
@Test func theAllowlistIsExactlyWhatWasEstablishedByRunningTheTools() {
    #expect(SanitizedEnvironment.allowed == [
        "PATH", "HOME", "TMPDIR",
        "USER", "LOGNAME", "SHELL",
        "LANG", "LC_ALL", "LC_CTYPE", "TERM",
        "__CF_USER_TEXT_ENCODING",
    ])
}

/// The filter is applied to the REAL environment at the point of use, so a
/// variable set after process start is filtered too.
@Test func forToolsFiltersTheLiveEnvironment() {
    let live = SanitizedEnvironment.forTools()
    #expect(live.keys.allSatisfy { SanitizedEnvironment.allowed.contains($0) },
            "leaked: \(live.keys.filter { !SanitizedEnvironment.allowed.contains($0) })")
    // The harness's own state-home override must NOT reach a child: a tool that
    // could read it is a tool that could be pointed at another run's state.
    #expect(live[StateHome.envKey] == nil)
}
