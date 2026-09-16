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

public enum SubprocessError: Error, CustomStringConvertible {
    case launchFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "launch failed: \(message)"
        }
    }
}

public enum Subprocess {
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
        let child: SpawnedChild
        do {
            child = try POSIXSpawn.spawn(executable: executable, args: args, cwd: cwd, env: env)
        } catch {
            throw SubprocessError.launchFailed("\(error)")
        }

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

        // The readers stop on EOF. If an orphan still holds a write end (which is
        // exactly what a broken tree kill leaves behind) EOF never arrives, so the
        // stop flag guarantees we return instead of hanging forever.
        buffers.requestStop()
        drains.wait()
        close(child.stdoutFD)
        close(child.stderrFD)

        let snapshot = buffers.snapshot()
        return ProcessResult(
            exitCode: reaped ? exitCode(from: status) : -1,
            stdout: String(decoding: snapshot.out, as: UTF8.self),
            stderr: String(decoding: snapshot.err, as: UTF8.self),
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
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 {
                    // Nothing available for 50 ms. Anything the child buffered has
                    // been read by now, so it is safe to honour a stop request.
                    if buffers.isStopRequested { return }
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
    private var stopRequested = false

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

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(out: out, err: err, truncated: truncated)
    }
}
