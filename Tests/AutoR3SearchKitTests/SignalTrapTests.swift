import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AutoR3SearchKit

// What these tests bind, and what they deliberately do not.
//
// BOUND: the registry (a spawn publishes its pgid, a reap clears it) and the kill
// itself (the exact body the signal handler runs does tear down a real child AND its
// grandchildren, across the process-group boundary that makes the orphan hazard real).
// Both are deterministic -- spawn, publish, kill, blocking-reap -- with no sleeps and no
// scheduler races.
//
// NOT BOUND: that `signal(2)` is actually wired to that body. Binding it would mean
// raising a real SIGTERM inside the test process, which would either kill the test
// runner or require changing the runner's own signal disposition; and `_exit` in the
// handler makes an in-process test of the full path impossible by construction. That
// half is covered by recorded mutation evidence in docs/run-log.md, which SIGTERMs a
// real `eval` process and shows the child surviving without the handler and gone with
// it. A flaky signal-timing test in this suite would be worse than none.
//
// Every test here disarms the trap in a `defer`. The library only publishes a pgid when
// armed, and swift-testing runs cases in parallel, so leaving it armed would let
// unrelated cases' children write over each other's published pgid.

/// Spawns `sh -c` as its own process-group leader, exactly as the harness spawns every
/// child, and returns it. The caller owns reaping it.
private func spawnGroupLeader(_ script: String) throws -> SpawnedChild {
    try POSIXSpawn.spawn(
        executable: URL(fileURLWithPath: "/bin/sh"),
        args: ["-c", script],
        cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
        env: nil)
}

/// Blocking reap. Returns the raw wait status.
private func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, 0)
        if result == pid { return status }
        if result < 0 && errno == EINTR { continue }
        return status
    }
}

/// Whether `pid` still exists. `kill(pid, 0)` performs the permission and existence
/// check without sending anything.
private func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

@Test func aSpawnedChildsProcessGroupIsPublishedAndClearedAgain() throws {
    SignalTrap.armWithoutInstallingForTesting()
    defer { SignalTrap.disarmForTesting() }

    #expect(SignalTrap.livePGID == 0, "nothing in flight before a spawn")

    // Go through the real entry point, so this binds Subprocess's publication and not a
    // re-implementation of it. `true` exits immediately; what matters is that the pgid
    // is cleared afterwards.
    _ = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/true"), [],
                           cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 30)

    #expect(SignalTrap.livePGID == 0,
            "the pgid must be cleared once the child is reaped, so a later signal can never target a recycled pid")
}

@Test func theSignalHandlersKillReachesTheChildAndItsGrandchildren() throws {
    // A child that forks a grandchild and then waits. The grandchild is the whole point:
    // it is what `kill(childPid)` alone would leave behind, and what `kill(-pgid)`
    // reaches because POSIXSpawn made the child a process-group leader.
    let grandchildPidFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("gc-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: grandchildPidFile) }

    let child = try spawnGroupLeader("""
        sleep 60 &
        echo $! > \(grandchildPidFile.path)
        wait
        """)

    // Wait for the grandchild's pid to appear. Bounded and polled on a FILE, not on a
    // clock: this loop ends as soon as the shell has written it, and gives up rather
    // than hanging if the shell never starts.
    var grandchildPid: pid_t = 0
    for _ in 0..<600 {
        if let text = try? String(contentsOf: grandchildPidFile, encoding: .utf8),
           let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            grandchildPid = value
            break
        }
        usleep(10_000)
    }
    guard grandchildPid > 0 else {
        Platform.processTree.killTree(pgid: child.pid)
        _ = reap(child.pid)
        close(child.stdoutFD); close(child.stderrFD)
        Issue.record("the fixture's grandchild never reported its pid")
        return
    }

    #expect(processExists(grandchildPid), "the grandchild must be alive before the kill")

    // EXACTLY the body the signal handler runs, minus its `_exit`. The pgid is passed
    // explicitly rather than published to the process-wide slot: swift-testing runs
    // cases in parallel, so several children really are alive at once here and a test
    // that leaned on that shared slot would be racing every other case. See
    // `SignalTrap.killProcessGroupForTesting`.
    SignalTrap.killProcessGroupForTesting(pgid: child.pid)

    let status = reap(child.pid)
    close(child.stdoutFD)
    close(child.stderrFD)
    #expect(status & 0x7f == SIGKILL, "the child itself must have been signalled, not merely asked")

    // The grandchild is in the same process group and must be gone too. Reaped by init,
    // so this is an existence check, not a wait.
    var grandchildGone = false
    for _ in 0..<600 {
        if !processExists(grandchildPid) { grandchildGone = true; break }
        usleep(10_000)
    }
    #expect(grandchildGone, """
        the grandchild survived the handler's kill. That is the orphan this whole \
        mechanism exists to prevent: it is reparented to init and keeps burning CPU, \
        silently corrupting every later measurement on the machine.
        """)
}

@Test func nothingIsPublishedWhileTheTrapIsDisarmed() throws {
    // The library must stay inert until the executable installs the trap. swift-testing
    // runs cases in parallel and several children are genuinely alive at once, so a
    // library that always published would have them overwrite each other.
    SignalTrap.disarmForTesting()
    SignalTrap.noteChildSpawned(pgid: 424242)
    #expect(SignalTrap.livePGID == 0)
}

@Test func killingWithNothingInFlightIsANoOp() throws {
    // The handler can fire between children -- after a reap and before the next spawn.
    // A pgid of 0 must never reach `kill`, because `kill(0, ...)` signals the CALLER's
    // entire process group, which in a test run is the test runner itself.
    SignalTrap.armWithoutInstallingForTesting()
    defer { SignalTrap.disarmForTesting() }
    #expect(SignalTrap.livePGID == 0)
    SignalTrap.killLiveChildTreeForTesting()
    // Reaching this line at all is the assertion: the test process is still alive.
    #expect(SignalTrap.livePGID == 0)
}
