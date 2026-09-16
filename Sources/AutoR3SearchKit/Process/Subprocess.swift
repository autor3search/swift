import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The outcome of one child process run.
///
/// A non-zero `exitCode` is *data*: a benchmark that fails is a verdict input, not
/// a harness crash. Only a failure to launch throws.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool, outputTruncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.outputTruncated = outputTruncated
    }
}

/// The outcome of one child process run, with stdout returned as raw bytes
/// instead of a UTF-8-repaired `String`.
///
/// `ProcessResult.stdout` goes through `String(decoding:as:)`, which
/// silently replaces any invalid byte sequence with U+FFFD — fine for text
/// output a caller only inspects, wrong for a caller that must round-trip
/// exact bytes (e.g. `Git.fileContents`, reading an arbitrary blob that may
/// be binary or saved in a non-UTF-8 encoding). `stderr` is still decoded as
/// `String` here: it is always a diagnostic message, never data a caller
/// round-trips.
public struct ProcessDataResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(exitCode: Int32, stdout: Data, stderr: String, timedOut: Bool, outputTruncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.outputTruncated = outputTruncated
    }
}

public enum SubprocessError: Error, CustomStringConvertible {
    case launchFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "launch failed: \(message)"
        }
    }
}

public enum Subprocess {
    /// How long the readers may keep draining after the child has been reaped.
    /// Bounds `run` even when a descendant escaped the tree kill and is still
    /// writing to the inherited pipe.
    static let drainGracePeriod: TimeInterval = 0.25

    /// Runs `executable` to completion, or kills its whole process tree at `timeout`.
    ///
    /// - Parameter outputCapBytes: per-stream cap. A runaway child cannot exhaust
    ///   memory; the overflow is discarded (but still drained) and
    ///   `outputTruncated` is set.
    public static func run(
        _ executable: URL,
        _ args: [String],
        cwd: URL,
        env: [String: String]? = nil,
        timeout: TimeInterval,
        outputCapBytes: Int = 4 << 20
    ) throws -> ProcessResult {
        let raw = try runRaw(executable, args, cwd: cwd, env: env, timeout: timeout, outputCapBytes: outputCapBytes)
        return ProcessResult(
            exitCode: raw.exitCode,
            stdout: String(decoding: raw.stdout, as: UTF8.self),
            stderr: String(decoding: raw.stderr, as: UTF8.self),
            timedOut: raw.timedOut,
            outputTruncated: raw.outputTruncated
        )
    }

    /// Like `run`, but returns stdout as the raw `Data` the child wrote,
    /// undecoded. See `ProcessDataResult` for why this exists alongside
    /// `run` rather than replacing it — `run`'s signature and behavior are
    /// unchanged, and eleven existing call sites keep working exactly as
    /// before.
    public static func runData(
        _ executable: URL,
        _ args: [String],
        cwd: URL,
        env: [String: String]? = nil,
        timeout: TimeInterval,
        outputCapBytes: Int = 4 << 20
    ) throws -> ProcessDataResult {
        let raw = try runRaw(executable, args, cwd: cwd, env: env, timeout: timeout, outputCapBytes: outputCapBytes)
        return ProcessDataResult(
            exitCode: raw.exitCode,
            stdout: raw.stdout,
            stderr: String(decoding: raw.stderr, as: UTF8.self),
            timedOut: raw.timedOut,
            outputTruncated: raw.outputTruncated
        )
    }

    /// Shared plumbing behind `run` and `runData`: spawn, drain both pipes
    /// concurrently, wait (with a tree kill at `timeout`), and hand back
    /// both streams as raw bytes. `run` and `runData` differ only in how
    /// they decode `stdout` afterward.
    private struct RawResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        let outputTruncated: Bool
    }

    private static func runRaw(
        _ executable: URL,
        _ args: [String],
        cwd: URL,
        env: [String: String]?,
        timeout: TimeInterval,
        outputCapBytes: Int
    ) throws -> RawResult {
        let child: SpawnedChild
        do {
            child = try POSIXSpawn.spawn(executable: executable, args: args, cwd: cwd, env: env)
        } catch {
            throw SubprocessError.launchFailed("\(error)")
        }

        // Publish this child's process group so a SIGTERM from `stop --force`
        // (or a Ctrl-C) can kill its whole tree before we die -- otherwise the
        // child, which is its own group leader, is orphaned to init and keeps
        // burning CPU, corrupting every later measurement on the machine. This
        // is a no-op unless the executable installed the trap; see
        // `SignalTrap`. Cleared below once the child has been reaped, so a
        // later signal can never target a recycled pid.
        //
        // `noteChildSpawned` returns `false` only when its fixed-size registry
        // is completely full -- every slot already holds a live pgid. Rather
        // than let this child run for its whole lifetime untracked by the
        // trap (the exact orphan hazard this file exists to prevent), refuse
        // outright: kill what was just spawned, reap it, and fail the launch.
        // This should never happen given this project's actual concurrency;
        // hitting it means something is badly wrong, and a loud failure here
        // is the only acceptable response to that, not a silent drop.
        guard SignalTrap.noteChildSpawned(pgid: child.pid) else {
            Platform.processTree.killTree(pgid: child.pid)
            var reapStatus: Int32 = 0
            waitpid(child.pid, &reapStatus, 0)
            close(child.stdoutFD)
            close(child.stderrFD)
            throw SubprocessError.launchFailed(
                "SignalTrap's live-child registry is full; refusing to run " +
                "\(executable.path) untracked by the SIGTERM/SIGINT trap")
        }
        defer { SignalTrap.noteChildReaped(pgid: child.pid) }

        // Drain both pipes concurrently, starting *before* we wait. A child that
        // fills the 64 KiB pipe buffer would otherwise block on write while we
        // block on wait — a deadlock that no timeout could distinguish from a slow
        // benchmark.
        let buffers = OutputBuffers(cap: outputCapBytes)
        let drains = DispatchGroup()
        drain(fd: child.stdoutFD, stream: .out, into: buffers, group: drains)
        drain(fd: child.stderrFD, stream: .err, into: buffers, group: drains)

        var status: Int32 = 0
        var timedOut = false
        var reaped = false
        let deadline = Date().addingTimeInterval(timeout)

        // Backoff, not a fixed tick: a fixed 10 ms poll would add up to 10 ms of
        // exit-detection latency to every run, which is pure noise in a timing
        // harness. Start tight for short children, relax for long ones.
        var idle: TimeInterval = 0.0005
        let maxIdle: TimeInterval = 0.02

        while true {
            let result = waitpid(child.pid, &status, WNOHANG)
            if result == child.pid { reaped = true; break }
            if result < 0 {
                if errno == EINTR { continue }
                break  // ECHILD and friends: nothing left to reap.
            }
            if Date() >= deadline {
                timedOut = true
                // pgid == pid: the child was spawned as its own group leader.
                Platform.processTree.killTree(pgid: child.pid)
                break
            }
            Thread.sleep(forTimeInterval: idle)
            idle = min(maxIdle, idle * 2)
        }

        if !reaped {
            // Blocking reap so no zombie is left behind.
            while true {
                let result = waitpid(child.pid, &status, 0)
                if result == child.pid { reaped = true; break }
                if result < 0 && errno == EINTR { continue }
                break
            }
        }

        // The readers stop on EOF. If something still holds a write end — a broken
        // tree kill, or a descendant that escaped the group by calling setsid for
        // itself — EOF never arrives, so the stop request bounds the wait two ways:
        // a quiet pipe ends it immediately, and a *noisy* one ends it at the grace
        // deadline. Without the second bound a runaway escapee keeps `poll` ready
        // forever and the harness hangs instead of reporting `timedOut`.
        buffers.requestStop(grace: drainGracePeriod)
        drains.wait()
        close(child.stdoutFD)
        close(child.stderrFD)

        let snapshot = buffers.snapshot()
        return RawResult(
            exitCode: reaped ? exitCode(from: status) : -1,
            stdout: snapshot.out,
            stderr: snapshot.err,
            timedOut: timedOut,
            outputTruncated: snapshot.truncated
        )
    }

    /// `wait(2)` status decoding; the `W*` macros are not available in Swift.
    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7f == 0 { return (status >> 8) & 0xff }  // WIFEXITED
        let signal = status & 0x7f
        if signal != 0 && signal != 0x7f { return 128 + signal }  // WIFSIGNALED
        return -1  // stopped, which we never wait for
    }

    private static func drain(
        fd: Int32,
        stream: OutputBuffers.Stream,
        into buffers: OutputBuffers,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let capacity = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }

            while true {
                let stop = buffers.stopState()
                // Hard wall-clock bound, checked *before* readability. A descendant
                // that escaped the process group can keep this pipe permanently
                // readable; without this check the reader would never reach the
                // quiet-pipe test below and `run` would never return.
                if stop.graceExpired { return }

                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 {
                    // Nothing available for 50 ms. Anything the child buffered has
                    // been read by now, so it is safe to honour a stop request.
                    if stop.requested { return }
                    continue
                }
                let count = read(fd, buffer, capacity)
                if count > 0 {
                    buffers.append(buffer, count: count, to: stream)
                } else if count == 0 {
                    return  // EOF: every write end is closed.
                } else {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
            }
        }
    }
}

/// Capped, lock-guarded accumulation of the two streams.
private final class OutputBuffers: @unchecked Sendable {
    enum Stream { case out, err }
    struct Snapshot { let out: Data; let err: Data; let truncated: Bool }

    private let lock = NSLock()
    private let cap: Int
    private var out = Data()
    private var err = Data()
    private var truncated = false
    /// nil until `requestStop`; afterwards, the instant the readers must give up
    /// even if the pipe is still readable.
    private var graceDeadline: Date?

    init(cap: Int) { self.cap = max(0, cap) }

    func append(_ bytes: UnsafePointer<UInt8>, count: Int, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        let used = stream == .out ? out.count : err.count
        let room = cap - used
        guard room > 0 else {
            // Keep reading (so the child is never blocked on a full pipe) but throw
            // the overflow away rather than growing without bound.
            truncated = true
            return
        }
        let taken = min(room, count)
        if stream == .out {
            out.append(bytes, count: taken)
        } else {
            err.append(bytes, count: taken)
        }
        if taken < count { truncated = true }
    }

    func requestStop(grace: TimeInterval) {
        lock.lock()
        graceDeadline = Date().addingTimeInterval(grace)
        lock.unlock()
    }

    /// `requested`: the child has been reaped, so a quiet pipe means we are done.
    /// `graceExpired`: give up now regardless of how much is still arriving.
    func stopState() -> (requested: Bool, graceExpired: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let graceDeadline else { return (false, false) }
        return (true, Date() >= graceDeadline)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(out: out, err: err, truncated: truncated)
    }
}
