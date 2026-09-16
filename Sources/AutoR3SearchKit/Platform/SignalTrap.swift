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
// at most ONE live child, and the "registry" is a single integer.
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

/// Process-group id of the child currently in flight, or 0 when none.
///
/// `sig_atomic_t` is the one type the C standard promises can be read and
/// written atomically with respect to signal delivery. Written by
/// `Subprocess.runRaw` around each spawn; read by the signal handler.
nonisolated(unsafe) private var liveChildPGID: sig_atomic_t = 0

/// Whether a trap has been installed. Until it has, `Subprocess` publishes
/// nothing -- which keeps this global untouched in the test process, where
/// swift-testing runs cases in parallel and several children really are alive
/// at once. The single-live-child invariant this type depends on is a property
/// of the `eval` EXECUTABLE, not of the library.
nonisolated(unsafe) private var trapArmed = false

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

/// The body of the handler, minus the exit: one load of a `sig_atomic_t`, then
/// the kill above.
private func killLiveChildTreeFromSignalContext() {
    killProcessGroupFromSignalContext(liveChildPGID)
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
        // Force both globals' lazy initialisation to completion BEFORE a
        // handler can possibly run -- see hazard (3) in the file comment.
        liveChildPGID = 0
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

    /// Records the process group of the child that is now in flight.
    ///
    /// KNOWN WINDOW, stated rather than papered over: a signal delivered
    /// between `posix_spawn` returning and this call lands while the pgid is
    /// still 0, and that one child is orphaned. The window is the few
    /// microseconds of a function return against a child that runs for seconds
    /// to minutes, and it cannot be closed with `pthread_sigmask`, which masks
    /// per-thread while the signal is process-directed and may be delivered to
    /// one of the pipe-drain threads instead. The residual failure is one
    /// orphan in a vanishingly rare interleaving, against one orphan in
    /// **every** forced stop without this trap.
    static func noteChildSpawned(pgid: pid_t) {
        guard trapArmed else { return }
        liveChildPGID = sig_atomic_t(pgid)
    }

    /// Records that no child is in flight. Called once the child has been
    /// reaped, so a later signal cannot signal a pid the kernel may since have
    /// recycled.
    static func noteChildReaped() {
        guard trapArmed else { return }
        liveChildPGID = 0
    }

    /// The currently published process group, for tests and diagnostics.
    static var livePGID: pid_t { pid_t(liveChildPGID) }

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

    /// As above, but reading the global exactly as the handler does. Used only
    /// to bind the "nothing in flight" case, where the value is unambiguously 0.
    static func killLiveChildTreeForTesting() {
        killLiveChildTreeFromSignalContext()
    }

    /// Test-only: undo `install()`'s arming so a test that publishes a pgid
    /// cannot leave the library in a state where parallel test cases publish
    /// over each other.
    static func disarmForTesting() {
        liveChildPGID = 0
        trapArmed = false
    }

    /// Test-only: arm without installing any OS handler, so the publication
    /// path can be exercised without changing the test process's signal
    /// disposition (which would break the test runner itself).
    static func armWithoutInstallingForTesting() {
        liveChildPGID = 0
        trapArmed = true
    }
}

#endif
