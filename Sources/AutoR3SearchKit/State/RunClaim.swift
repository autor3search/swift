// Sources/AutoR3SearchKit/State/RunClaim.swift
//
// One run, one writer. `eval` is the only command that mutates a run's state
// -- it restores frozen files over the repository, advances
// `measurementCommit`, re-points the pinned worktree and appends to
// `results.tsv` -- so two evals addressing the same run at the same time is
// never a legitimate configuration, only an accident (an agent loop that
// fired twice, an operator running `eval` by hand while the loop is going).
//
// Two concrete corruptions this prevents, both observed as real hazards
// during earlier tasks:
//
//  1. `results.tsv` (Task 14). `ResultsTSV.append` decides whether to write
//     the header by checking the file's SIZE. Two appends that both observe
//     an empty file both write a header; two appends that interleave at the
//     `seekToEnd`/`write` boundary can tear a row. The header check is
//     correct for one writer and cannot be made correct for many without a
//     lock, so the lock is what it gets.
//  2. The baseline advance (Task 17). Two evals that both read
//     `baseline.json`, both KEEP, and both write it back leave the
//     measurement point at whichever finished last -- silently discarding
//     one of the two advances, which is exactly the stale-baseline bug the
//     advance exists to prevent.
//
// REFUSE, DO NOT QUEUE. A blocking lock would make the second eval sit and
// wait for however long the first takes (a full measurement session is
// minutes), and then run against a repository whose HEAD, worktree and
// frozen files the first eval has since changed underneath it. The second
// eval's answer would be to a question nobody asked. Non-blocking, refuse,
// say so.
//
// WHY `flock` AND NOT AN `O_EXCL` LOCK FILE. A lock file created with
// `O_CREAT|O_EXCL` and removed on exit leaks the moment the process does not
// reach its cleanup -- `kill -9`, a panic, a laptop lid closed overnight --
// and the next eval then cannot tell "a run is genuinely in flight" from "a
// run died three hours ago". Recovering means heuristics (is that pid still
// alive? is it still OUR binary, or a recycled pid?) that are wrong on
// exactly the rare occasions they matter. An advisory `flock` is held by the
// kernel against the open file description, so it is released
// unconditionally when the process dies, however it dies. A killed eval
// therefore leaks nothing: the file remains, the LOCK does not, and
// `isHeld` reports the truth without consulting a pid at all.
//
// SECOND LIMITATION, MEASURED RATHER THAN ASSUMED: the `O_CLOEXEC` below acts
// at EXEC, not at FORK. `fork` copies the whole descriptor table, so between a
// child's fork and its exec the claim's open file description -- and therefore
// its lock -- has two holders, and the original holder's `close` does not drop
// it. A claim released in that instant can keep reading as held for roughly a
// millisecond. Measured here at 0/1500 acquire-release cycles with nothing else
// spawning and 54/1500 with six threads spawning `git` continuously, in the
// same process; see docs/run-log.md.
//
// This window is strictly CONSERVATIVE and is left as it is on purpose. In
// 6000 measured cycles the lock was never granted twice at once: the window can
// only make a free claim look busy (an `eval` that refuses a run it could have
// taken, and re-runs), never let two evals measure together. Closing it would
// mean abandoning `flock` for POSIX record locks, which are NOT inherited
// across fork -- but which are also per-PROCESS, so two evals in one process
// would stop conflicting at all, and the same-process refusal this whole file
// exists to guarantee would silently become a no-op. The fail-safe window is
// the better trade.
//
// LIMITATION, STATED HERE AND NOT ONLY IN A REPORT: `flock` is ADVISORY and is
// not reliable over NFS or SMB. If `AUTOR3SEARCH_SWIFT_STATE_HOME` points at a
// network mount -- the one place an operator is most likely to put shared
// state, and the one place two machines could genuinely race -- the kernel may
// grant the lock to two processes at once and this protection silently does
// nothing. Keep the state home on a local filesystem. The default (the OS cache
// directory) already is one; an override is the only way to get this wrong.
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RunClaimError: Error, CustomStringConvertible, Equatable {
    /// Another live process holds this run's claim.
    case alreadyHeld(path: String, holder: String)

    /// The claim file could not be opened or created at all.
    case cannotOpen(path: String, code: Int32)

    public var description: String {
        switch self {
        case .alreadyHeld(let path, let holder):
            let who = holder.isEmpty ? "(the claim file records no holder details)" : holder
            return """
            another eval already holds this run's claim (\(path)). \(who) Two evals on one run \
            would race on the baseline record, the pinned worktree, the frozen files restored \
            over the repository and the results log, so the second one refuses rather than \
            queues: by the time it got its turn, the first would have changed HEAD, the \
            worktree and the working tree underneath it and its answer would be to a question \
            nobody asked. Wait for the running eval to finish, or stop it.
            """
        case .cannotOpen(let path, let code):
            return "could not open the run claim at \(path): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

/// The platform seam for the run claim, per spec.md 13 ("Run claim lock. A
/// real lock, so two evals cannot address one run"), in the same shape as
/// `ProcessTreeKilling`: a protocol with a POSIX conformance today and room
/// for a Windows conformance (`LockFileEx` with
/// `LOCKFILE_FAIL_IMMEDIATELY`) later, without restructuring `EvalRunner`.
///
/// Deliberately expressed in terms of a descriptor rather than a closure:
/// `eval`'s claim is held across the whole gate chain, including subprocess
/// calls that can run for minutes, so the lifetime is owned by `RunClaim`
/// and its `defer`, not by a scoped `withLock { }`.
public protocol RunClaimLocking: Sendable {
    /// Opens (creating if necessary) the claim file and returns a descriptor.
    func openClaimFile(path: String) throws -> Int32

    /// Attempts a NON-BLOCKING exclusive lock. `false` means another live
    /// process holds it; this must never wait.
    func tryLockExclusive(descriptor: Int32) -> Bool

    /// Truncates the claim file to zero bytes and writes `text`.
    func rewrite(descriptor: Int32, text: String)

    /// Reads the whole claim file's current contents.
    func readAll(descriptor: Int32) -> String

    /// Closes the descriptor, which also releases any lock held on it.
    func closeClaimFile(descriptor: Int32)
}

#if canImport(Darwin) || os(Linux)

public struct POSIXRunClaimLock: RunClaimLocking {
    public init() {}

    public func openClaimFile(path: String) throws -> Int32 {
        // O_CLOEXEC is load-bearing, not hygiene. `eval` spawns `swift
        // build`, `swift test`, `git` and `BenchmarkTool` through
        // `POSIXSpawn`, which sets up file actions only for the pipes it
        // creates and therefore lets every other descriptor be inherited.
        // Without O_CLOEXEC a benchmark process that outlived its parent --
        // precisely the orphan case `ProcessTreeKilling` exists for --
        // would keep this descriptor open and so keep the flock held after
        // eval had exited, wedging every later eval on the run with
        // "already held" and no holder to point at.
        let fd = cOpenClaim(path)
        guard fd >= 0 else { throw RunClaimError.cannotOpen(path: path, code: errno) }
        return fd
    }

    public func tryLockExclusive(descriptor: Int32) -> Bool {
        flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    public func rewrite(descriptor: Int32, text: String) {
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    public func readAll(descriptor: Int32) -> String {
        _ = lseek(descriptor, 0, SEEK_SET)
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { read(descriptor, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            out.append(contentsOf: buffer[0..<n])
            if out.count > 64 * 1024 { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public func closeClaimFile(descriptor: Int32) {
        _ = close(descriptor)
    }
}

private func cOpenClaim(_ path: String) -> Int32 {
    #if canImport(Darwin)
    return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    #else
    return Glibc.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    #endif
}

#endif

/// An acquired, exclusive claim on one run. Released by `release()`, which
/// is idempotent, and by `deinit` as a backstop -- but callers must still
/// `defer { claim.release() }` rather than rely on deinit timing.
public final class RunClaim {
    public let url: URL
    private let lock: any RunClaimLocking
    private let descriptor: Int32
    private var released = false

    private init(url: URL, lock: any RunClaimLocking, descriptor: Int32) {
        self.url = url
        self.lock = lock
        self.descriptor = descriptor
    }

    /// Takes the claim, or throws `RunClaimError.alreadyHeld` immediately.
    ///
    /// The body written into the file is for a human (and for `status`): the
    /// LOCK, not the body, is the authority on whether a run is in flight,
    /// so a stale body left behind by a killed eval is harmless.
    public static func acquire(
        at url: URL,
        lock: any RunClaimLocking = Platform.runClaimLock,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        host: String = ProcessInfo.processInfo.hostName,
        now: Date = Date()
    ) throws -> RunClaim {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = try lock.openClaimFile(path: url.path)
        guard lock.tryLockExclusive(descriptor: fd) else {
            // Read the holder's own description before letting go of our
            // (unlocked) descriptor. Reading needs no lock: the body is
            // advisory text, and a torn read of it only degrades the
            // diagnostic, never the refusal itself.
            let holder = lock.readAll(descriptor: fd).trimmingCharacters(in: .whitespacesAndNewlines)
            lock.closeClaimFile(descriptor: fd)
            throw RunClaimError.alreadyHeld(path: url.path, holder: holder)
        }
        let formatter = ISO8601DateFormatter()
        lock.rewrite(
            descriptor: fd,
            text: "pid=\(pid) host=\(host) started=\(formatter.string(from: now)) tool=\(BuildInfo.version)\n")
        return RunClaim(url: url, lock: lock, descriptor: fd)
    }

    /// Releases the claim. Truncates the body first so the file left behind
    /// records no holder, then closes the descriptor, which is what actually
    /// drops the kernel's lock.
    ///
    /// The file itself is deliberately NOT unlinked. Unlink-on-release is the
    /// classic lock-file race: a second process that has already opened the
    /// file, and is about to try the lock, ends up locking an inode that has
    /// been unlinked while a third process creates a fresh file at the same
    /// path and locks that -- two "holders", no conflict between them.
    /// Leaving the file in place makes the path stable for the lifetime of
    /// the run directory, so every process locks the same inode.
    public func release() {
        guard !released else { return }
        released = true
        lock.rewrite(descriptor: descriptor, text: "")
        lock.closeClaimFile(descriptor: descriptor)
    }

    deinit { release() }

    /// Whether some live process currently holds this run's claim, asked the
    /// only way that cannot be wrong: by trying to take it.
    ///
    /// Checking for the FILE's existence would be wrong in both directions --
    /// present but unlocked after any completed or killed run (false
    /// positive), and the lock is what a claim actually is. `status`
    /// (Task 18) reports "whether an eval is in flight" from this.
    public static func isHeld(at url: URL, lock: any RunClaimLocking = Platform.runClaimLock) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let fd = try? lock.openClaimFile(path: url.path) else { return false }
        defer { lock.closeClaimFile(descriptor: fd) }
        // Taking it proves nobody else had it; closing immediately gives it
        // straight back. There is no window in which this holds the claim
        // against a real eval for longer than one syscall pair, and an eval
        // that loses that race simply refuses and is re-run.
        return !lock.tryLockExclusive(descriptor: fd)
    }
}

extension Platform {
    #if canImport(Darwin) || os(Linux)
    public static let runClaimLock: any RunClaimLocking = POSIXRunClaimLock()
    #endif
}
