import Testing
import Foundation
@testable import AutoR3SearchKit

private let sh = URL(fileURLWithPath: "/bin/sh")
private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

@Test func nonZeroExitIsDataNotAnError() throws {
    // A failing child is a verdict input, never a harness crash.
    let r = try Subprocess.run(sh, ["-c", "exit 7"], cwd: tmp, env: nil,
                               timeout: 10, outputCapBytes: 1 << 20)
    #expect(r.exitCode == 7)
    #expect(r.timedOut == false)
}

@Test func capturesStdoutAndStderrSeparately() throws {
    let r = try Subprocess.run(sh, ["-c", "echo out; echo err 1>&2"], cwd: tmp, env: nil,
                               timeout: 10, outputCapBytes: 1 << 20)
    #expect(r.stdout.contains("out"))
    #expect(r.stderr.contains("err"))
}

@Test func capsOutputInsteadOfExhaustingMemory() throws {
    let r = try Subprocess.run(sh, ["-c", "yes abcdefghij | head -c 5000000"], cwd: tmp, env: nil,
                               timeout: 30, outputCapBytes: 64 * 1024)
    #expect(r.outputTruncated == true)
    #expect(r.stdout.utf8.count <= 64 * 1024 + 1024)
}

@Test func timeoutKillsTheWholeTreeNotJustTheChild() throws {
    // The grandchild writes to a marker file every 0.2s. If the tree is killed
    // correctly the file stops growing; an orphan keeps writing after we return.
    let marker = tmp.appendingPathComponent("tree-\(UUID().uuidString).txt")
    let script = "sh -c 'while true; do echo tick >> \(marker.path); sleep 0.2; done' & wait"
    let r = try Subprocess.run(sh, ["-c", script], cwd: tmp, env: nil,
                               timeout: 1.0, outputCapBytes: 1 << 20)
    #expect(r.timedOut == true)

    let sizeAtKill = (try? Data(contentsOf: marker).count) ?? 0
    Thread.sleep(forTimeInterval: 1.5)
    let sizeLater = (try? Data(contentsOf: marker).count) ?? 0
    #expect(sizeLater == sizeAtKill, "grandchild survived the timeout and is still writing")
    try? FileManager.default.removeItem(at: marker)
}

// The two tests below are additions, not part of the brief's four. The posix_spawn
// rewrite hand-rolls cwd (posix_spawn_file_actions_addchdir_np) and the envp array
// that Foundation's Process would otherwise have supplied; nothing above exercises
// either, and eleven later call sites depend on both being right.

@Test func runsInTheGivenWorkingDirectory() throws {
    let dir = tmp.appendingPathComponent("cwd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "hello-cwd".write(to: dir.appendingPathComponent("marker.txt"),
                          atomically: true, encoding: .utf8)

    // A bare relative path only resolves if the child really chdir'd.
    let r = try Subprocess.run(sh, ["-c", "cat marker.txt"], cwd: dir, env: nil,
                               timeout: 10, outputCapBytes: 1 << 20)
    #expect(r.exitCode == 0)
    #expect(r.stdout.contains("hello-cwd"))
}

@Test func passesAnExplicitEnvironmentAndInheritsWhenNil() throws {
    let explicit = try Subprocess.run(sh, ["-c", "printf '%s' \"$AUTOR3_PROBE\""], cwd: tmp,
                                      env: ["AUTOR3_PROBE": "explicit", "PATH": "/usr/bin:/bin"],
                                      timeout: 10, outputCapBytes: 1 << 20)
    #expect(explicit.stdout == "explicit")

    let inherited = try Subprocess.run(sh, ["-c", "printf '%s' \"${HOME:-missing}\""], cwd: tmp,
                                       env: nil, timeout: 10, outputCapBytes: 1 << 20)
    #expect(inherited.stdout == ProcessInfo.processInfo.environment["HOME"] ?? "missing")
}

/// `posix_spawn_file_actions_addchdir_np` rejects a path past PATH_MAX at *add*
/// time (ENAMETOOLONG, verified on this machine). If that return value is ignored
/// the file-action list simply ends up with no chdir entry, `posix_spawn` then
/// succeeds, and the child runs in the HARNESS's own directory — a benchmark
/// quietly measuring the wrong source tree. That must be a launch failure, not a
/// result.
@Test func aFailedSpawnSetupIsLoudNotSilent() throws {
    let tooLong = URL(fileURLWithPath: "/" + String(repeating: "a", count: 4000))
    #expect(throws: SubprocessError.self) {
        _ = try Subprocess.run(sh, ["-c", "pwd"], cwd: tooLong, env: nil,
                               timeout: 10, outputCapBytes: 1 << 20)
    }
}

/// The tree kill reaches everything *in the group*. A descendant that calls
/// `setsid` for itself leaves the group entirely and survives — and it still holds
/// the inherited stdout pipe, so EOF never arrives and the pipe never goes quiet.
/// Draining must therefore be bounded by wall clock, not by the child falling
/// silent: otherwise the harness hangs here instead of reporting `timedOut`.
///
/// The time limit is the backstop, the `elapsed` expectation is the assertion — a
/// regression must fail the test, not wedge the suite.
@Test(.timeLimit(.minutes(1)))
func drainStaysBoundedWhenADescendantEscapesTheProcessGroup() throws {
    let pidFile = tmp.appendingPathComponent("escapee-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }

    // setsid() succeeds here because the backgrounded perl is not a group leader
    // (its parent sh is). It then writes every 5 ms for ~20 s, comfortably shorter
    // than poll's 50 ms window, so the pipe is always ready and a reader that only
    // stops on a quiet pipe would never stop.
    let script = """
    /usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(my $f, ">", "\(pidFile.path)"); \
    print $f $$; close $f; $| = 1; \
    for (1..4000) { print "escaped\\n"; select(undef, undef, undef, 0.005); }' &
    wait
    """

    let started = Date()
    let r = try Subprocess.run(sh, ["-c", script], cwd: tmp, env: nil,
                               timeout: 1.0, outputCapBytes: 1 << 20)
    let elapsed = Date().timeIntervalSince(started)

    // The escapee is unreachable by the tree kill by construction, so clean it up
    // explicitly rather than leaving a stray process on the machine.
    if let text = try? String(contentsOf: pidFile, encoding: .utf8),
       let escapee = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        kill(escapee, SIGKILL)
    }

    #expect(r.timedOut == true)
    #expect(elapsed < 5.0,
            "run() blocked for \(elapsed)s draining a descendant that escaped the process group")
}
