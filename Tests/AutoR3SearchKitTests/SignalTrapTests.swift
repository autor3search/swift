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
// NO TEST HERE ARMS THE TRAP, and none writes the process-wide slot. An earlier version
// did, and the 10x rerun that was supposed to prove it non-flaky could not have seen the
// flake: it was run as `--filter SignalTrapTests`, which executes only these four cases
// and therefore excludes the ~180 others that create the hazard. Under a full parallel
// run, while the trap is armed, EVERY case that spawns through `Subprocess` -- the git
// fixtures, `EvalRunnerTests`, `BaselineRunnerTests`, `SubprocessTests` -- publishes its
// own child's pgid into that one slot. Two interleavings follow: a test that reads the
// slot sees someone else's live pgid and fails, and a test that kills "whatever is in
// the slot" SIGKILLs an unrelated case's child, failing it with a git error nobody would
// trace back to this file.
//
// So every test below reaches the logic through EXPLICIT PARAMETERS, exactly as the kill
// test already did. Nothing here needs `.serialized`, because nothing here shares state.

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

/// Renamed from `aSpawnedChildsProcessGroupIsPublishedAndClearedAgain`, which overstated
/// what it bound: it asserted the slot was 0 before and 0 after and never observed a
/// non-zero publication at all, so deleting `SignalTrap.noteChildSpawned(pgid:)` from
/// `Subprocess.runRaw` left it green. Observing a real publication requires arming the
/// process-wide trap, which -- see the header -- cannot be done safely while other cases
/// spawn in parallel. So this now asserts the property it can actually hold, under a name
/// that says so, and the publication call site is bound instead by the mutation evidence
/// in docs/run-log.md: with the handler installed, a real `BenchmarkTool` child is killed
/// on SIGTERM, which is only possible if `runRaw` published its pgid.
@Test func theLibraryPublishesNothingUntilTheExecutableInstallsTheTrap() throws {

    #expect(SignalTrap.livePGID == 0,
            "nothing may be published before the executable installs the trap")

    // A real spawn through the real entry point. If `Subprocess` published
    // unconditionally instead of gating on the trap being armed, this would come back
    // non-zero for the duration of the child -- and, across the rest of this suite,
    // parallel cases would be overwriting each other's pgids in one shared slot.
    _ = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/true"), [],
                           cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 30)

    #expect(SignalTrap.livePGID == 0, """
        the library published a pgid without the trap being installed. Nothing in this \
        test suite arms it, so this must hold for the whole run -- it is the property \
        that makes it safe for every other case here to spawn children in parallel.
        """)
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

@Test func killingWithNothingInFlightTouchesNothingAtAll() throws {
    // The handler can fire BETWEEN children -- after one is reaped and before the next
    // is spawned -- when the slot holds 0. `kill(0, ...)` signals the CALLER's entire
    // process group, so without the `pgid > 0` guard that case would signal the test
    // runner (in production, the shell that started eval and every other job in it).
    //
    // Asserting merely "the test process survived" would be weak. This spawns a real
    // process group, asks for a kill of pgid 0 and of a negative pgid, and asserts the
    // real child is STILL ALIVE afterwards -- so the guard is observed to stop the call,
    // not just to avoid killing us.
    let child = try spawnGroupLeader("sleep 60")
    defer {
        SignalTrap.killProcessGroupForTesting(pgid: child.pid)
        _ = reap(child.pid)
        close(child.stdoutFD)
        close(child.stderrFD)
    }
    #expect(processExists(child.pid), "the fixture child must be alive to begin with")

    // Only 0 is exercised, deliberately. `kill(-1, ...)` signals every process the user
    // can signal, so a test that relied on the guard to stop THAT would destroy the
    // developer's session the day the guard broke. With 0 the blast radius of a broken
    // guard is this test runner's own process group: loud, and contained.
    SignalTrap.killProcessGroupForTesting(pgid: 0)

    #expect(processExists(child.pid), """
        a kill request with no live child reached `kill` anyway. With pgid 0 that signals \
        the caller's own process group -- in production, the shell that started eval.
        """)
}

// The two tests below bind the multi-slot registry added to fix the CRITICAL
// finding that `profile`'s second live child (the sampler attached to the
// benchmark being profiled) silently overwrote the first's pgid in a
// single-slot registry. Neither arms the trap or touches the real,
// process-wide registry: `ChildRegistrySlots` takes its storage as an
// explicit parameter specifically so "the registry is full" can be tested
// against a small, test-owned buffer without racing or polluting every
// other case that spawns through `Subprocess` in parallel -- the same
// reason the kill tests above thread the pgid through explicitly instead of
// reading the shared slot.

@Test func theRegistrySlotsClaimReleaseAndRefuseWhenFull() throws {
    let capacity = 2
    let slots = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: capacity)
    slots.initialize(repeating: 0, count: capacity)
    defer { slots.deallocate() }

    #expect(ChildRegistrySlots.claim(111, in: slots, count: capacity),
            "the first slot must be claimable")
    #expect(ChildRegistrySlots.claim(222, in: slots, count: capacity),
            "the second slot must be claimable")
    #expect(!ChildRegistrySlots.claim(333, in: slots, count: capacity), """
        a third claim must be refused once both slots already hold a live pgid -- a \
        dropped pgid here is the exact silent-orphan failure this registry exists to \
        eliminate, not an edge case to tolerate.
        """)

    // Releasing one of the two live pgids -- matched by VALUE -- frees exactly that
    // slot and no other.
    ChildRegistrySlots.release(111, in: slots, count: capacity)
    #expect(ChildRegistrySlots.claim(444, in: slots, count: capacity),
            "releasing one live pgid must free exactly one slot for reuse")

    // 222 (never released) and 444 (just claimed) must still occupy both slots. A
    // release for a pgid that was never registered must be a silent no-op, not
    // accidentally free something it was never holding.
    ChildRegistrySlots.release(999, in: slots, count: capacity)
    #expect(!ChildRegistrySlots.claim(555, in: slots, count: capacity),
            "both slots must still be occupied (222 and 444); a no-op release must not free either")
}

@Test func noteChildSpawnedRefusesOnceEveryProductionSlotIsFull() throws {
    // `SignalTrap.noteChildSpawned` is, at the trap-armed case, exactly
    // `ChildRegistrySlots.claim` against its own process-wide buffer sized
    // `SignalTrap.capacity` (8) -- so filling an identically-sized LOCAL
    // buffer via the same claim function binds "returns false once full" at
    // the exact size production actually uses, without arming the trap.
    let capacity = SignalTrap.capacity
    let slots = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: capacity)
    slots.initialize(repeating: 0, count: capacity)
    defer { slots.deallocate() }

    for pgid in 1...capacity {
        #expect(ChildRegistrySlots.claim(sig_atomic_t(pgid), in: slots, count: capacity),
                "slot for pgid \(pgid) of \(capacity) must still be claimable")
    }
    #expect(!ChildRegistrySlots.claim(sig_atomic_t(capacity + 1), in: slots, count: capacity), """
        every one of SignalTrap's \(capacity) production slots is full; one more claim must \
        be refused, matching exactly what noteChildSpawned returns to Subprocess.runRaw and \
        Sampler.profile once the registry is exhausted.
        """)
}

@Test func refuseUntrackedChildKillsReapsAndFailsTheLaunch() throws {
    // Binds the REFUSAL PATH itself -- kill, blocking reap, fd cleanup, the
    // specific thrown error -- independent of how a `false` registration
    // outcome was produced (a full `SignalTrap` registry in production).
    // `Subprocess.refuseUntrackedChild` is called directly with a real,
    // just-spawned child: no trap armed, no shared state touched, so this
    // cannot race or pollute any other case running in parallel.
    let child = try spawnGroupLeader("sleep 60")
    #expect(processExists(child.pid), "the fixture child must be alive to begin with")

    let error = Subprocess.refuseUntrackedChild(child, executable: URL(fileURLWithPath: "/bin/sh"))

    #expect(!processExists(child.pid), """
        the just-spawned child must actually be killed and reaped, not leaked, when it \
        cannot be registered with the SIGTERM/SIGINT trap -- an untracked live child for \
        even one instant is the exact orphan hazard this refusal exists to prevent.
        """)
    let description = "\(error)"
    #expect(description.contains("registry is full"), "the failure reason must be named, not generic")
    #expect(description.contains("untracked"), "the failure reason must name what was refused, and why")
}
