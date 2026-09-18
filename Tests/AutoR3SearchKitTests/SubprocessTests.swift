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

// MARK: - Linux portability: descriptor hygiene, ETXTBSY, and a late reader

/// A spawned child must inherit fd 0/1/2 AND NOTHING ELSE.
///
/// This is not tidiness. `posix_spawn` forks, and the fork inherits every
/// descriptor this process has open that is not close-on-exec -- including one
/// another thread opened for WRITING moments earlier. On Linux the kernel then
/// refuses to `execve` that file for as long as the child lives: ETXTBSY,
/// "Text file busy". The harness builds `BenchmarkTool` and immediately spawns
/// it, so a leaked writable descriptor turns into a failed measurement launch.
///
/// `/dev/fd/N` exists on both macOS (devfs) and Linux (a symlink to
/// `/proc/self/fd`) exactly while fd N is open, so the child can report the
/// answer itself with no platform-specific probe. The descriptor is moved to a
/// deliberately high number first, so a number `sh` happens to open for its own
/// purposes cannot be mistaken for the one under test.
@Test func aSpawnedChildInheritsNoDescriptorAboveStderr() throws {
    let marker = tmp.appendingPathComponent("fd-leak-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: marker) }
    FileManager.default.createFile(atPath: marker.path, contents: Data())

    let opened = open(marker.path, O_WRONLY)
    try #require(opened >= 0, "could not open the marker file for writing")
    let probeFD: Int32 = 33
    try #require(dup2(opened, probeFD) == probeFD, "could not move the descriptor to \(probeFD)")
    // ONLY if `open` did not already hand us the probe number. `dup2(n, n)` is
    // a no-op that returns n without closing anything, so an unconditional
    // `close(opened)` there would close the descriptor under test and leave
    // this asserting against a descriptor that is not open -- which passes,
    // for entirely the wrong reason. Not hypothetical: under the full parallel
    // suite this process reaches descriptor numbers in the thirties.
    if opened != probeFD { close(opened) }
    defer { close(probeFD) }
    // The descriptor must actually BE open, or "the child did not inherit it"
    // is true for a reason that has nothing to do with the code under test.
    try #require(fcntl(probeFD, F_GETFD) >= 0, "fd \(probeFD) is not open, so this test proves nothing")

    let r = try Subprocess.run(
        sh, ["-c", "if [ -e /dev/fd/\(probeFD) ]; then echo INHERITED; else echo CLEAN; fi"],
        cwd: tmp, env: nil, timeout: 30, outputCapBytes: 1 << 20)

    #expect(r.exitCode == 0, "probe failed: \(r.stderr)")
    #expect(r.stdout.contains("CLEAN"),
            "the child inherited fd \(probeFD), open for WRITING in the parent: \(r.stdout)")
}

#if os(Linux)
/// Drains a child spawned directly through `POSIXSpawn` (not through
/// `Subprocess.run`, which does not expose the descriptor-closing strategy) and
/// returns its stdout once it has exited. Small and blocking on purpose: the
/// children it is used with print one word and exit.
private func runDirectlySpawned(
    _ executable: URL, _ args: [String], cwd: URL, closing: InheritedDescriptorClosing
) throws -> String {
    let child = try POSIXSpawn.spawn(
        executable: executable, args: args, cwd: cwd, env: nil, closing: closing)
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(child.stdoutFD, $0.baseAddress, $0.count) }
        if count > 0 { collected.append(contentsOf: buffer[0..<count]) } else { break }
    }
    close(child.stdoutFD)
    close(child.stderrFD)
    var status: Int32 = 0
    waitpid(child.pid, &status, 0)
    return String(decoding: collected, as: UTF8.self)
}

/// THE FALLBACK MUST ACTUALLY WORK, not merely exist.
///
/// `posix_spawn_file_actions_addclosefrom_np` is glibc 2.34 and later. Ubuntu
/// 20.04, Debian 11 and RHEL 8 are all older, and on those the enumerating
/// strategy is the ONLY thing standing between a spawned child and every
/// descriptor this process has open. A fallback that has never executed is not
/// a fallback, so this runs it explicitly, on the platform it is for.
///
/// Linux only, and that is not laziness: see `InheritedDescriptorClosing`.
/// Darwin refuses the whole spawn with EBADF if a close action names a
/// descriptor that closed between the snapshot and the fork, and it has
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` on every supported release, so it has neither
/// the tolerance this strategy needs nor any need for the strategy.
@Test func theEnumeratingFallbackClosesInheritedDescriptorsToo() throws {
    let marker = tmp.appendingPathComponent("fd-fallback-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: marker) }
    FileManager.default.createFile(atPath: marker.path, contents: Data())

    let opened = open(marker.path, O_WRONLY)
    try #require(opened >= 0, "could not open the marker file for writing")
    let probeFD: Int32 = 34
    try #require(dup2(opened, probeFD) == probeFD, "could not move the descriptor to \(probeFD)")
    // See the note in `aSpawnedChildInheritsNoDescriptorAboveStderr`: closing
    // `opened` unconditionally closes the probe itself when `open` already
    // returned this number. The `contains(probeFD)` expectation below is what
    // caught that, in a real full-suite run, rather than letting the test pass
    // while proving nothing.
    if opened != probeFD { close(opened) }
    defer { close(probeFD) }

    // The enumeration must SEE the descriptor before it can be expected to
    // close it -- otherwise a fallback that silently enumerated nothing would
    // pass this test for the wrong reason.
    #expect(openDescriptorsAboveStderr().contains(probeFD),
            "the enumeration did not find fd \(probeFD), so the rest of this test proves nothing")

    let probe = "if [ -e /dev/fd/\(probeFD) ]; then echo INHERITED; else echo CLEAN; fi"
    let out = try runDirectlySpawned(sh, ["-c", probe], cwd: tmp, closing: .enumerateOpenDescriptors)
    #expect(out.contains("CLEAN"),
            "the enumerating fallback left fd \(probeFD) open in the child: \(out)")
}
#endif

/// The reader must still drain the pipe when libdispatch did not schedule it
/// until long after the child was reaped.
///
/// This is the mechanism behind a zero-byte `git show` that returns exit 0:
/// under a saturated global queue the drain block can sit unstarted for longer
/// than `drainGracePeriod`, and a grace deadline anchored at reap time would
/// already have expired before the reader ran a single `poll`. The loop would
/// return having read nothing, and the caller would receive an EMPTY stdout
/// carrying the child's real, successful exit status -- silent data loss that
/// the truncation guard in `Git.fileContents` cannot see, because nothing was
/// truncated: nothing was read.
///
/// Driven against a plain pipe rather than a real child so the late start is
/// staged exactly instead of hoped for: the bytes are already buffered and the
/// write end already closed, so a correct reader has no excuse to return empty.
@Test(.timeLimit(.minutes(1)))
func aReaderScheduledLateStillDrainsWhatTheChildAlreadyWrote() throws {
    var fds: [Int32] = [-1, -1]
    try #require(pipe(&fds) == 0, "pipe() failed")
    defer { close(fds[0]) }

    let payload = Data(repeating: 0x78, count: 4096)  // "x" * 4096, as GitTests writes
    let written = payload.withUnsafeBytes { raw in
        write(fds[1], raw.baseAddress, raw.count)
    }
    try #require(written == payload.count, "short write staging the pipe")
    close(fds[1])  // EOF is already available; every byte is already buffered.

    let buffers = OutputBuffers(cap: 4 << 20)
    buffers.requestStop()  // the child has been reaped, as in `runRaw`

    // Four times the grace period: a deadline started by `requestStop` is long
    // gone by the time this reader gets to run.
    Subprocess.drainLoop(fd: fds[0], stream: .out, into: buffers,
                         startDelay: Subprocess.drainGracePeriod * 4)

    let drained = buffers.snapshot().out
    #expect(drained == payload,
            "a late-scheduled reader returned \(drained.count) of \(payload.count) bytes")
}

#if os(Linux)
/// Linux only, because only Linux enforces ETXTBSY.
///
/// Staged the one way that is deterministic: this process itself holds a
/// writable descriptor on the executable, so the first `execve` is guaranteed
/// to be refused. A second thread closes that descriptor shortly afterwards,
/// which is the real-world shape of the problem -- a writer that is about to
/// finish, not one that never will. Without the bounded ETXTBSY retry in
/// `POSIXSpawn.spawn` the launch throws; with it, the spawn waits the window
/// out and the child runs.
@Test(.timeLimit(.minutes(1)))
func aSpawnRefusedWithETXTBSYIsRetriedUntilTheWriterFinishes() throws {
    let script = tmp.appendingPathComponent("etxtbsy-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: script) }
    try "#!/bin/sh\necho ran\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let holder = open(script.path, O_WRONLY)
    try #require(holder >= 0, "could not hold the script open for writing")

    DispatchQueue(label: "etxtbsy-writer").asyncAfter(deadline: .now() + 0.1) { close(holder) }

    let r = try Subprocess.run(script, [], cwd: tmp, env: nil, timeout: 30,
                               outputCapBytes: 1 << 20)
    #expect(r.exitCode == 0)
    #expect(r.stdout.contains("ran"))
}
#endif
