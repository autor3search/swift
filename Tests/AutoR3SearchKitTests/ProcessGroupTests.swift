import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/ProcessGroupTests.swift
//
// THE TWELFTH VECTOR, and the honest limit of the fix for it.
//
// Round 6 guards the BYTES being measured. This one changes no bytes: a
// candidate benchmark whose `countWords` is the original quadratic
// implementation spawns background CPU burners that OUTLIVE it, idling while
// the candidate runs and saturating the machine during the BASELINE samples
// that follow. `MeasureSession` interleaves B,C,B,C, so every baseline sample
// after the first runs on a loaded machine. The asymmetry is the trick: the
// process running the agent's code can leave something behind that penalises
// the side it is compared against.
//
// Measured against the real binary, in-group burners spawned with
// `posix_spawn`:
//
//   before: rc 0  keep  k 1  ratio 0.51843  baseline 7.45 ms  candidate 3.86 ms
//                                           12 burners still alive afterwards
//   after:  rc 1  discard k 1 ratio 1.01978  baseline 4.09 ms
//                                           0 burners still alive
//
// The fix is that every `Subprocess.run` now ends with a process-group kill,
// not only the timeout path. That is a correctness fix before it is a security
// one: each sample is supposed to be an independent observation, and a process
// surviving between samples breaks that whether it is malicious or a leaked
// helper.

/// THE PATTERN GOES THROUGH THE ENVIRONMENT, NEVER THE COMMAND LINE.
///
/// `pgrep -f` matches against the whole command line of every process -- which
/// includes the command line of the shell that is running `pgrep` itself. Spell
/// the marker inline and the matcher matches its OWN wrapper, reporting a hit
/// for a process that is nothing but the question being asked. Measured: on
/// Linux (dash, which does not exec-optimize a command followed by `||`) this
/// made three tests report survivors that did not exist; macOS happened not to
/// show it, which is exactly the kind of difference that makes "it passes on my
/// machine" worthless here. An environment variable is not part of a command
/// line, so the wrapper cannot match itself.
private func runMatcher(_ tool: String, _ needle: String) -> String {
    let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "AUTOR3_MARKER": needle]
    guard let r = try? Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "\(tool) -f \"$AUTOR3_MARKER\" || true"],
        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), env: env, timeout: 30)
    else { return "" }
    return r.stdout
}

private func pidsMatching(_ needle: String) -> [String] {
    runMatcher("pgrep", needle).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

private func reap(_ needle: String) {
    _ = runMatcher("pkill", needle)
}

/// A grandchild left running in the child's own process group does NOT survive
/// the run. This is the leak the interleaved measurement cannot tolerate.
@Test func aLeakedGrandchildInTheGroupDoesNotSurviveTheRun() throws {
    let marker = "autor3search-group-test-\(UUID().uuidString)"
    defer { reap(marker) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    // `sleep` backgrounded by a non-interactive shell stays in the shell's
    // group, and the shell is the group leader the harness spawned.
    let r = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "/bin/sh -c 'sleep 45' \(marker) & echo spawned"],
        cwd: tmp, env: nil, timeout: 30)
    #expect(r.exitCode == 0, "\(r.stderr)")
    #expect(r.stdout.contains("spawned"), "the run itself must still work normally")

    // The kill happens before `run` returns, so there is nothing to wait for.
    #expect(pidsMatching(marker).isEmpty,
            "a grandchild in the group survived the run: \(pidsMatching(marker))")
}

/// THE ESCAPE THE GROUP KILL COULD NOT REACH, now closed.
///
/// A child that puts itself in a NEW process group escapes `kill(-pgid)`, and
/// this is not an exotic manoeuvre: Foundation's own `Process` does it for
/// every child it spawns -- measured directly, a `Process`-spawned child
/// reports `pgid == its own pid` while a `posix_spawn`ed one inherits the
/// parent's group. So the easiest way to write the attack was the way that got
/// away, and it landed at `rc 0 keep ratio 0.54278` with twelve burners alive.
///
/// `setpgid` cannot leave a SESSION. Every spawn is now a session leader and
/// the teardown sweeps the session, so the escape stops working by
/// construction rather than by detection.
@Test func aGrandchildThatLeavesTheGroupIsStillKilledBySessionSweep() throws {
    let marker = "autor3search-escape-test-\(UUID().uuidString)"
    defer { reap(marker) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    // The parent stays alive for a moment, which is what a real benchmark does:
    // it spawns the helper and then runs for a second or more. Without that the
    // kill lands before the helper has finished calling `setpgrp` and the
    // escape loses a race it would not lose in practice -- itself worth
    // knowing, and the reason this sleep is here rather than being tidied away.
    let escape = """
        /usr/bin/python3 -c "import os,time; os.setpgrp(); time.sleep(45)" \(marker) & \
        /bin/sleep 1; echo spawned
        """
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", escape],
                               cwd: tmp, env: nil, timeout: 30)
    #expect(r.exitCode == 0, "\(r.stderr)")

    // Give it a moment to call setpgrp and settle.
    Thread.sleep(forTimeInterval: 0.3)
    #expect(pidsMatching(marker).isEmpty, """
        a process that left the group survived the run: \(pidsMatching(marker)). The session \
        sweep is what is supposed to reach it -- setpgid cannot leave a session.
        """)
}

/// The spawn really does put the child in its own session, which is the
/// precondition everything above rests on. A libc that refused
/// `POSIX_SPAWN_SETSID` would fail here rather than silently degrading to the
/// old group-only behaviour.
@Test func everySpawnedChildIsItsOwnSessionLeader() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let child = try POSIXSpawn.spawn(
        executable: URL(fileURLWithPath: "/bin/sleep"), args: ["5"], cwd: tmp, env: nil)
    defer {
        kill(child.pid, SIGKILL)
        var st: Int32 = 0
        waitpid(child.pid, &st, 0)
        close(child.stdoutFD)
        close(child.stderrFD)
    }
    #expect(child.sessionIsolated, "POSIX_SPAWN_SETSID was refused by this libc")
    #expect(getsid(child.pid) == child.pid, "the child is not a session leader")
    #expect(getpgid(child.pid) == child.pid, """
        SETSID must also make the child a process-group leader, or kill(-pgid) stops reaching the \
        group and the inner guarantee is lost
        """)
    #expect(getsid(child.pid) != getsid(0), """
        the child shares the harness's session -- sweeping it would kill the harness
        """)
}

/// THE GUARD THAT KEEPS THIS FROM BEING A FOOT-GUN. A sweep aimed at our own
/// session, or at pid 0/1, must do nothing at all.
@Test func theSessionSweepRefusesToTouchItsOwnSessionOrInit() {
    let tree = POSIXProcessTree()
    #expect(tree.killSession(sid: getsid(0)).isEmpty,
            "sweeping our own session would kill the harness")
    #expect(tree.killSession(sid: 0).isEmpty)
    #expect(tree.killSession(sid: 1).isEmpty, "pid 1 inside a container is the one fatal mistake")
    #expect(tree.killSession(sid: -1).isEmpty)
}

/// THE FALLBACK, ACTUALLY EXERCISED. A libc that refuses `POSIX_SPAWN_SETSID`
/// -- glibc older than 2.26 -- must still be able to launch anything at all.
/// There is no way to make a working libc refuse the real flag, so the spawn
/// takes a test-only override that REPLACES it with one the platform rejects;
/// the retry then clears that same bit, exactly as it would clear the real one.
///
/// The failure must be visible in `sessionIsolated`, because that flag is what
/// stops the teardown sweeping a session the child never got -- which would be
/// the harness's own.
@Test func aLibcThatRefusesSessionIsolationStillLaunchesTheChild() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    // Measured on this platform: flag 0x1000 makes posix_spawn fail (rc 88),
    // while 0x800 and 0x2000 are ignored outright -- which is why the fallback
    // triggers on ANY failure rather than on one errno.
    let child = try POSIXSpawn.spawn(
        executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "echo fellback"],
        cwd: tmp, env: nil, setsidFlagOverride: Int16(0x1000))
    defer {
        close(child.stdoutFD)
        close(child.stderrFD)
    }
    #expect(!child.sessionIsolated, """
        the spawn reported session isolation it did not get; the teardown would then sweep the \
        harness's own session
        """)
    // It still launched, and still landed in its own process group, so the
    // inner guarantee survives the fallback.
    #expect(getpgid(child.pid) == child.pid || errno == ESRCH,
            "the fallback must still make the child a process-group leader")
    var status: Int32 = 0
    waitpid(child.pid, &status, 0)
    #expect(status == 0)
}

/// ...and the ordinary path is unaffected by the seam existing: with no
/// override, session isolation is what actually happens.
@Test func theDefaultSpawnPathStillTakesSessionIsolation() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let child = try POSIXSpawn.spawn(
        executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "exit 0"], cwd: tmp, env: nil)
    defer {
        close(child.stdoutFD)
        close(child.stderrFD)
    }
    #expect(child.sessionIsolated)
    var status: Int32 = 0
    waitpid(child.pid, &status, 0)
}

/// The enumeration agrees with the kernel: our own session contains our own
/// pid, and a session id nothing belongs to enumerates empty.
@Test func sessionEnumerationAgreesWithTheKernel() {
    let members = POSIXProcessTree.pidsInSession(getsid(0))
    #expect(members.contains(getpid()), "our own pid must be in our own session")
    #expect(POSIXProcessTree.pidsInSession(999_000).isEmpty,
            "a session id nothing belongs to must enumerate empty")
}

/// The kill must not disturb the ordinary path: exit status, stdout and stderr
/// all still arrive intact, and a non-zero exit is still reported as data.
@Test func theGroupKillDoesNotDisturbOrdinaryRuns() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let ok = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                                ["-c", "printf out; printf err >&2; exit 0"],
                                cwd: tmp, env: nil, timeout: 30)
    #expect(ok.exitCode == 0)
    #expect(ok.stdout == "out")
    #expect(ok.stderr == "err")

    let bad = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 7"],
                                 cwd: tmp, env: nil, timeout: 30)
    #expect(bad.exitCode == 7, "a non-zero exit is data and must survive the kill")
    #expect(!bad.timedOut)

    // A large output still round-trips: the kill happens after the child is
    // reaped but before the drains are stopped, so it must not truncate.
    let big = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "i=0; while [ $i -lt 2000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done"],
        cwd: tmp, env: nil, timeout: 60)
    #expect(big.exitCode == 0)
    #expect(big.stdout.split(separator: "\n").count == 2000,
            "output was truncated by the teardown: got \(big.stdout.count) bytes")
}

/// ...and a timeout still reports `timedOut`, with the tree killed, exactly as
/// before. The new unconditional kill sits alongside that path, not instead of
/// it.
@Test func aTimeoutStillReportsTimedOutAndStillKillsTheTree() throws {
    let marker = "autor3search-timeout-test-\(UUID().uuidString)"
    defer { reap(marker) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let r = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "/bin/sh -c 'sleep 45' \(marker) & /bin/sleep 45"],
        cwd: tmp, env: nil, timeout: 1)
    #expect(r.timedOut)
    #expect(pidsMatching(marker).isEmpty, "the timeout path must still reach grandchildren")
}
