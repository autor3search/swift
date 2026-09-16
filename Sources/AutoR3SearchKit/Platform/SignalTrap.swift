// Sources/AutoR3SearchKit/Platform/SignalTrap.swift
//
// `stop --force` sends SIGTERM to the `eval` process. A human pressing Ctrl-C
// sends SIGINT. With the default disposition either one terminates the process
// IMMEDIATELY: no Swift `defer` runs, no cleanup of any kind happens, and --
// the part that matters -- the child currently in flight is not touched.
//
// WHY THE CHILD SURVIVES. Every child is spawned as its own process-group
// leader (`POSIX_SPAWN_SETPGROUP`, see `POSIXSpawn`; `pgid == pid`). That is
// deliberate: it is what makes the timeout path's `kill(-pgid)` reach
// grandchildren. But it also means nothing propagates the parent's death
// across the group boundary. A forced stop during an in-flight experiment
// therefore leaves the running `swift build`, `swift test` or `BenchmarkTool`
// orphaned, reparented to init, and still burning CPU and IO.
//
// That is mistake #4 from this project's founding constraints, word for word:
// "Kill the whole process tree on timeout. Orphaned benchmark processes
// survive and silently corrupt every later measurement on the machine." Task 2
// bound it with mutation evidence on the TIMEOUT path and explicitly deferred
// this one, recording that "the only real fix is a SIGINT handler calling
// killTree over a registry of live children -- that registry has no owner at
// task 2". `eval` is that owner: it runs children strictly sequentially --
// build, then test, then each measurement round -- so at any instant there is
// at most ONE live child.
//
// TASK 20 CORRECTION: "at most one live child" is a property of `eval` and
// `baseline`, not of every executable that installs this trap. `profile`
// holds TWO children alive at once for the whole sampling window -- the
// benchmark it is profiling, and the sampler (`sample`/`perf`) attached to
// it -- and a single-slot registry silently OVERWRITES the first pgid with
// the second the moment the sampler spawns, which is exactly the orphan
// this file exists to prevent: reproduced live, `kill -TERM` during
// `profile`'s sampling window left the benchmark reparented to pid 1 at
// 100% CPU, because the registry pointed at the sampler, not it. The
// registry below is therefore a small FIXED-CAPACITY SET of live pgids
// (`maxLiveChildren` slots), not a single integer -- still no allocation,
// no ARC and no locks inside the handler, just a few more `kill(2)` calls
// over a few more already-allocated words of memory.
//
// WHY NOT `kill(-evalPid)` FROM `stop --force`. It looks like the obvious fix
// and reaches nothing: the children are deliberately NOT in eval's process
// group. Signalling eval's group signals eval and whatever shell started it,
// and leaves every child exactly where it was.
//
// ---------------------------------------------------------------------------
// RAW HANDLER, NOT `DispatchSource.makeSignalSource`
// ---------------------------------------------------------------------------
//
// `DispatchSource` is the more comfortable API -- it runs the handler on an
// ordinary queue, so none of the async-signal-safety rules below apply. It was
// rejected for one reason: arming it requires setting the signal's disposition
// to SIG_IGN first, and from that moment the process IGNORES SIGTERM. If the
// dispatch source is then not serviced for any reason -- queue starvation, a
// thread-pool that will not grow, a source cancelled or deallocated by a code
// path added later -- `stop --force` silently does nothing at all and the run
// continues to completion. An operator who asked for a stop and got no stop,
// with no error, is a worse failure than a handler that must be written
// carefully. The raw handler's disposition means the signal is always acted
// on; the cost is that its body must be async-signal-safe, which is a cost
// paid once, here, in eight lines.
//
// ASYNC-SIGNAL-SAFETY, CONCRETELY. A handler installed with `signal(2)` may
// call only async-signal-safe functions. Allocation, `print`, ARC traffic,
// locks and most of Foundation are not. Everything the handler below touches
// is either a plain load/store of a `sig_atomic_t` or one of `kill(2)` and
// `_exit(2)`, both of which POSIX lists as async-signal-safe. Three specific
// hazards are closed deliberately:
//
//   1. `killTree` is reached through the CONCRETE `POSIXProcessTree`, not
//      through `Platform.processTree` (an `any ProcessTreeKilling`). It is the
//      same method body the timeout path runs -- there is still exactly one
//      killing path in this project -- but reaching it concretely means no
//      existential access, no witness-table indirection and no possibility of
//      ARC traffic on a boxed value.
//   2. The handler and its helper are TOP-LEVEL functions, not methods on a
//      type, so calling them cannot trigger lazy type-metadata instantiation.
//   3. A Swift global `var` in a library is initialised lazily, via
//      `swift_once`, on first access -- and taking a `swift_once` lock inside
//      a signal handler is a deadlock waiting for the right timing. `install()`
//      therefore WRITES both globals before installing the handler, so the
//      once has already completed and the handler's access is a plain load.
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || os(Linux)

/// Fixed capacity for concurrently live child process groups. `eval` and
/// `baseline` run children strictly sequentially (one live child at a time);
/// `profile` genuinely holds TWO at once for the whole sampling window -- the
/// benchmark it is profiling, and the sampler (`sample`/`perf`) attached to
/// it. 8 is ample headroom over the two this project currently ever needs at
/// once, with room to spare should a future command need a third or fourth.
private let maxLiveChildren = 8

/// Fixed-capacity, signal-handler-safe storage for up to `maxLiveChildren`
/// live child process-group ids, indexed `0..<maxLiveChildren`, each either 0
/// (free) or a live pgid.
///
/// A raw `malloc`'d buffer, not a Swift `Array`: allocated exactly ONCE, in
/// `install()`, before the handler can possibly run (see hazard (3) below),
/// so the handler and both `note*` functions afterward only ever do pointer
/// arithmetic over ALREADY-allocated memory -- no allocation, no ARC, none of
/// Swift `Array`'s own copy-on-write machinery, none of which is
/// async-signal-safe. `sig_atomic_t` is the one type the C standard promises
/// can be read and written atomically with respect to signal delivery.
nonisolated(unsafe) private var liveChildPGIDs: UnsafeMutablePointer<sig_atomic_t>?

/// Whether a trap has been installed. Until it has, `Subprocess` publishes
/// nothing -- which keeps the registry untouched in the test process, where
/// swift-testing runs cases in parallel and several children really are alive
/// at once. The single-live-child invariant `eval`/`baseline` depend on is a
/// property of those EXECUTABLES, not of the library.
nonisolated(unsafe) private var trapArmed = false

/// The registry's claim/release logic, parameterized over an explicit
/// buffer and slot count rather than reaching for the process-wide global
/// directly. Still pure pointer arithmetic -- no allocation, no ARC, safe to
/// call from `noteChildSpawned`/`noteChildReaped` -- but taking storage as a
/// parameter also makes it directly testable: a test can exercise "the
/// registry is full" against a small, test-owned buffer it allocates and
/// frees itself, without arming the trap or touching the shared,
/// process-wide registry every other parallel test spawns through. See
/// `SignalTrapTests` for exactly that.
enum ChildRegistrySlots {
    /// Claims the first free (zero) slot for `pgid`. `false` if all `count`
    /// slots already hold a live pgid.
    @discardableResult
    static func claim(
        _ pgid: sig_atomic_t, in slots: UnsafeMutablePointer<sig_atomic_t>, count: Int
    ) -> Bool {
        for index in 0..<count where slots[index] == 0 {
            slots[index] = pgid
            return true
        }
        return false
    }

    /// Clears the slot holding `pgid`, matched by VALUE -- never an index --
    /// so this can only ever clear the slot that actually holds `pgid`. A
    /// `pgid` not currently present is a silent no-op.
    static func release(
        _ pgid: sig_atomic_t, in slots: UnsafeMutablePointer<sig_atomic_t>, count: Int
    ) {
        for index in 0..<count where slots[index] == pgid {
            slots[index] = 0
            return
        }
    }
}

/// Kills one process group. Async-signal-safe: a comparison and, at most, two
/// `kill(2)` calls.
///
/// The `pgid > 0` guard is load-bearing, not defensive noise: `kill(0, ...)`
/// signals the CALLER's entire process group, so a handler firing between two
/// children -- after one is reaped and before the next is spawned -- would
/// otherwise signal the shell that started `eval`, and every other job in it.
private func killProcessGroupFromSignalContext(_ pgid: sig_atomic_t) {
    guard pgid > 0 else { return }
    // Concrete type on purpose -- see hazard (1) in the file comment. This is
    // the same `killTree` the timeout path in `Subprocess.runRaw` calls: a
    // negative pid signals the whole group (this is the line that reaches
    // grandchildren), then the leader directly as belt and braces.
    POSIXProcessTree().killTree(pgid: pid_t(pgid))
}

/// The body of the handler, minus the exit: kills EVERY currently-registered
/// pgid, not just one -- `profile` genuinely has two live children (the
/// benchmark and the sampler attached to it) for the whole sampling window,
/// and a handler that only ever killed "the" child would leave whichever one
/// is not in the single slot orphaned. Reading a few more already-allocated
/// words of memory and issuing a few more `kill(2)` calls is exactly as
/// async-signal-safe as reading one word and issuing two.
private func killLiveChildTreeFromSignalContext() {
    guard let slots = liveChildPGIDs else { return }
    for index in 0..<maxLiveChildren {
        killProcessGroupFromSignalContext(slots[index])
    }
}

private func terminatingSignalHandler(_ signalNumber: Int32) {
    killLiveChildTreeFromSignalContext()
    // `_exit`, not `exit`: `exit(3)` runs atexit handlers and flushes stdio,
    // neither of which is async-signal-safe. 128 + signal is the conventional
    // encoding for "terminated by this signal" and is deliberately OUTSIDE
    // eval's 0...3 verdict range -- a forced stop produces no verdict at all,
    // and must not be mistakable for one.
    _exit(128 + signalNumber)
}

/// Installs, and feeds, the terminating-signal trap.
public enum SignalTrap {
    /// Traps SIGTERM (what `stop --force` sends) and SIGINT (Ctrl-C), so that
    /// either one kills the in-flight child's whole process tree before this
    /// process exits.
    ///
    /// Call once, from the executable, before any child is spawned. Returns
    /// false if the OS refused to install a handler, so the caller can warn
    /// rather than silently believe it is protected.
    @discardableResult
    public static func install() -> Bool {
        // Force both globals' lazy initialisation to completion, AND the
        // registry buffer's one-time allocation, BEFORE a handler can
        // possibly run -- see hazard (3) in the file comment. Allocated only
        // once: a second `install()` call (there is no legitimate reason for
        // one, but nothing prevents it) re-zeroes the existing buffer instead
        // of leaking a second one.
        if let existing = liveChildPGIDs {
            existing.update(repeating: 0, count: maxLiveChildren)
        } else {
            let buffer = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: maxLiveChildren)
            buffer.initialize(repeating: 0, count: maxLiveChildren)
            liveChildPGIDs = buffer
        }
        trapArmed = true

        // `signal(2)` rather than `sigaction(2)`: the struct's handler member
        // is spelled differently on Darwin (`__sigaction_u`) and glibc
        // (`__sigaction_handler`), and the only `sigaction` feature this needs
        // -- a handler that stays installed across delivery -- is what both
        // platforms' `signal(2)` already provides. The handler `_exit`s
        // immediately, so re-entry and restart semantics are moot either way.
        // Success is checked through `errno` rather than by comparing the
        // returned handler against `SIG_ERR`: a C function pointer is not
        // Equatable in Swift, and bit-casting one to compare it is a worse
        // trade than clearing errno and reading it back, which is exactly what
        // `signal(2)` documents.
        var installed = true
        for signalNumber in [SIGTERM, SIGINT] {
            errno = 0
            _ = signal(signalNumber, terminatingSignalHandler)
            if errno != 0 { installed = false }
        }
        return installed
    }

    /// Claims a free slot for the process group of a child that is now in
    /// flight. Returns `true` once the trap is not armed at all (nothing to
    /// track) or the pgid is now registered; returns `false` ONLY when the
    /// registry is completely full -- all `maxLiveChildren` slots already
    /// hold a live pgid.
    ///
    /// A `false` return is NOT swallowed anywhere in this file: the two call
    /// sites (`Subprocess.runRaw`, `Sampler.profile`) both treat it as a
    /// launch failure and kill the child they just spawned rather than let
    /// it run untracked by the SIGTERM/SIGINT trap for its whole lifetime --
    /// an untracked child during a forced stop is exactly the orphan this
    /// whole file exists to prevent, and silently dropping the newest pgid
    /// here would recreate that bug quietly instead of fixing it. This
    /// should never happen given this project's actual concurrency (`eval`:
    /// one child at a time; `profile`: two at once, eight slots of
    /// headroom), so hitting it is itself a sign something is badly wrong.
    ///
    /// KNOWN WINDOW, stated rather than papered over: a signal delivered
    /// between `posix_spawn` returning and this call lands before the slot is
    /// claimed, and that one child is orphaned. The window is the few
    /// microseconds of a function return against a child that runs for seconds
    /// to minutes, and it cannot be closed with `pthread_sigmask`, which masks
    /// per-thread while the signal is process-directed and may be delivered to
    /// one of the pipe-drain threads instead. The residual failure is one
    /// orphan in a vanishingly rare interleaving, against one orphan in
    /// **every** forced stop without this trap.
    @discardableResult
    static func noteChildSpawned(pgid: pid_t) -> Bool {
        guard trapArmed, let slots = liveChildPGIDs else { return true }
        return ChildRegistrySlots.claim(sig_atomic_t(pgid), in: slots, count: maxLiveChildren)
    }

    /// The registry's fixed slot count (8), exposed so a test can allocate
    /// its own buffer of exactly this size and exercise "every slot full"
    /// against it via `ChildRegistrySlots` directly -- see
    /// `SignalTrapTests.noteChildSpawnedRefusesOnceEveryProductionSlotIsFull`.
    static let capacity = maxLiveChildren

    /// Clears `pgid`'s own slot, matched by VALUE -- never "the last slot
    /// written", and never an index the caller happens to remember -- so
    /// reaping one of several concurrently live children can only ever clear
    /// THAT child's slot, never another live child's. Called once the child
    /// has been reaped, so a later signal cannot signal a pid the kernel may
    /// since have recycled. A pgid that is not currently registered (the trap
    /// was not armed when it was spawned, or `noteChildSpawned` refused it)
    /// is a silent no-op, matching `noteChildSpawned`'s own "nothing to
    /// track" case.
    static func noteChildReaped(pgid: pid_t) {
        guard trapArmed, let slots = liveChildPGIDs else { return }
        ChildRegistrySlots.release(sig_atomic_t(pgid), in: slots, count: maxLiveChildren)
    }

    /// The first currently-published process group found in the registry, or
    /// 0 if none -- for tests and diagnostics. With more than one child live
    /// at once (only `profile` does this) this reports just one of them;
    /// nothing in this file relies on it for more than "is anything
    /// registered right now", which is all the existing tests ask of it.
    static var livePGID: pid_t {
        guard let slots = liveChildPGIDs else { return 0 }
        for index in 0..<maxLiveChildren where slots[index] != 0 {
            return pid_t(slots[index])
        }
        return 0
    }

    /// Runs exactly the body the signal handler runs, minus the `_exit`.
    ///
    /// Exists so a test can bind the kill itself deterministically -- spawn a
    /// real process group, invoke this, and reap -- without having to raise a
    /// real signal and race the scheduler. What it does NOT bind is the
    /// `signal(2)` wiring; that is covered by the recorded mutation evidence in
    /// docs/run-log.md, which kills a real `eval` process.
    ///
    /// Takes the pgid EXPLICITLY rather than reading the global. The library
    /// publishes to one process-wide slot -- correct for the `eval` executable,
    /// which has exactly one child in flight, but not for a swift-testing run,
    /// where cases execute in parallel and several children are genuinely alive
    /// at once. A test that armed the trap and then asserted the global still
    /// held ITS pgid would be racing every other case in the suite. Threading
    /// the value through removes the shared state from the test entirely, which
    /// is why this is not flaky.
    static func killProcessGroupForTesting(pgid: pid_t) {
        killProcessGroupFromSignalContext(sig_atomic_t(pgid))
    }

    // DELIBERATELY NO `armForTesting` / `disarmForTesting`.
    //
    // An earlier version of this file had them, and they were a trap of their
    // own. `trapArmed` and the registry are PROCESS-WIDE, and swift-testing
    // runs cases in parallel: while any test had the trap armed, EVERY other
    // case that spawned through `Subprocess` -- the git fixtures, the eval
    // tests, the baseline tests -- would publish its own child's pgid into
    // the same registry, for tens to hundreds of milliseconds each, across a
    // 25-second run. Two interleavings follow directly: a test that reads the
    // registry sees another case's live pgid, and, far worse, a test that
    // kills "whatever is registered" SIGKILLs an unrelated case's child and
    // fails it with a confusing error nobody would trace back here.
    //
    // The library is therefore inert until the executable arms it, no test
    // ever arms it, and every test below reaches the logic through explicit
    // parameters instead of through the global. `theLibraryPublishesNothing...`
    // is what holds that property in place.
}

#endif
