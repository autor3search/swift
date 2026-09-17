import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Killing a timed-out benchmark means killing *everything it started*.
///
/// A naive `kill(childPid)` leaves grandchildren running: they are reparented to
/// init and keep burning CPU, which silently corrupts every later measurement on
/// the machine. This seam exists so a Windows implementation (job objects) can be
/// added later without restructuring the runner.
///
/// Spawning deliberately does **not** go through this protocol. The child is made
/// its own process-group leader by `posix_spawn` (see `POSIXSpawn` below, also part
/// of the platform layer); the protocol only signals the group that spawn created.
public protocol ProcessTreeKilling: Sendable {
    /// Signal every process in the group led by `pgid`.
    func killTree(pgid: pid_t)
}

#if canImport(Darwin) || os(Linux)

public struct POSIXProcessTree: ProcessTreeKilling {
    public init() {}

    public func killTree(pgid: pid_t) {
        // A negative pid signals the entire process group. This is the line that
        // reaches grandchildren; without it orphans survive the timeout.
        kill(-pgid, SIGKILL)
        // Belt and braces: if the group is already empty but the leader lingers,
        // still signal the direct child.
        kill(pgid, SIGKILL)
    }
}

// MARK: - Spawning

/// A live child plus the read ends of its captured pipes.
///
/// `pid` doubles as the process-group id: the child is spawned as its own
/// process-group leader, so `pgid == pid`.
public struct SpawnedChild: Sendable {
    public let pid: pid_t
    public let stdoutFD: Int32
    public let stderrFD: Int32
}

public enum SpawnError: Error, CustomStringConvertible {
    case pipeFailed(Int32)
    case setupFailed(call: String, code: Int32)
    case spawnFailed(path: String, code: Int32)

    public var description: String {
        switch self {
        case .pipeFailed(let code):
            return "pipe() failed: \(String(cString: strerror(code))) (\(code))"
        case .setupFailed(let call, let code):
            return "\(call) failed: \(String(cString: strerror(code))) (\(code))"
        case .spawnFailed(let path, let code):
            return "posix_spawn(\(path)) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

/// How a spawn keeps the child from inheriting descriptors above stderr.
///
/// Two strategies, because the good one is not available everywhere. The
/// enumerating strategy is not a theoretical fallback: it is what runs on any
/// glibc older than 2.34 -- Ubuntu 20.04, Debian 11, RHEL 8 -- and on this
/// project's own CI it is exercised deliberately, by setting
/// `AUTOR3SEARCH_SWIFT_FD_CLOSE=enumerate`, so it cannot rot unnoticed.
public enum InheritedDescriptorClosing: Sendable {
    /// Whatever this platform does best: `POSIX_SPAWN_CLOEXEC_DEFAULT` on
    /// Darwin, `posix_spawn_file_actions_addclosefrom_np` on a glibc new
    /// enough to have it, and `enumerateOpenDescriptors` on one that is not.
    /// Race-free on the first two: the kernel decides at exec time, so a
    /// descriptor another thread opens after this point is still closed.
    case platformDefault

    #if !canImport(Darwin)
    /// Read the process's OWN open descriptors and add one close action per
    /// descriptor above stderr.
    ///
    /// TWO HONEST LIMITATIONS, and together they are why this is the fallback
    /// and not the default -- and why it is NOT offered on Darwin at all.
    ///
    /// 1. The list is a SNAPSHOT taken before the fork. A descriptor another
    ///    thread opens between the snapshot and the fork is still inherited.
    ///    The window is microseconds and the bounded ETXTBSY retry covers the
    ///    consequence, but `closefrom` has no window at all.
    /// 2. The same race runs the other way: a descriptor in the snapshot that
    ///    another thread CLOSES before the fork leaves a close action pointing
    ///    at a dead descriptor. glibc tolerates exactly that -- its spawn
    ///    implementation ignores a close failure for a descriptor below
    ///    `RLIMIT_NOFILE`, and musl ignores close failures outright -- so on
    ///    Linux a stale entry is harmless. **Darwin does not tolerate it**:
    ///    measured here, `posix_spawn` returns `EBADF (9)` and the launch
    ///    fails. That is not a reason to make the snapshot cleverer; it is the
    ///    reason this case does not exist on Darwin, which has
    ///    `POSIX_SPAWN_CLOEXEC_DEFAULT` on every supported release and
    ///    therefore never needs a fallback.
    case enumerateOpenDescriptors
    #endif
}

/// `posix_spawn_file_actions_addclosefrom_np` looked up at RUN time instead of
/// called directly.
///
/// A direct call would bind this file to glibc >= 2.34 at COMPILE time: on an
/// older glibc the symbol is not merely missing at link time, it is not
/// declared in `spawn.h` at all, so the package would fail to build with a
/// "no such module member" error on someone else's machine -- a machine we
/// would never see. `dlsym` turns that hard build floor into a runtime branch
/// this file can actually handle. Resolved once per process.
///
/// `nil` means either "this libc does not have it" or "the operator asked for
/// the fallback"; both take the same path, which is what makes forcing the
/// fallback a real exercise of the real code rather than a simulation of it.
#if !canImport(Darwin)
private typealias AddCloseFromFunction =
    @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32

private let resolvedAddCloseFrom: AddCloseFromFunction? = {
    if ProcessInfo.processInfo.environment["AUTOR3SEARCH_SWIFT_FD_CLOSE"] == "enumerate" {
        return nil
    }
    // A null handle is RTLD_DEFAULT: search the global symbol scope.
    guard let symbol = dlsym(nil, "posix_spawn_file_actions_addclosefrom_np") else { return nil }
    return unsafeBitCast(symbol, to: AddCloseFromFunction.self)
}()
#endif

/// Every descriptor above stderr this process has open RIGHT NOW.
///
/// `/proc/self/fd` (Linux) and `/dev/fd` (Darwin) both list exactly the open
/// descriptors, which keeps the resulting action list to the handful that are
/// really open instead of a thousand speculative closes. Where neither exists,
/// a bounded scan with `fcntl(F_GETFD)` finds them the slow way; the bound is
/// deliberate, because `_SC_OPEN_MAX` can legitimately be 1048576 and building
/// a million file actions per spawn would be worse than the leak.
///
/// Everything returned is re-checked with `fcntl` immediately before it is
/// used, so a descriptor that the directory read itself opened and closed
/// cannot end up in the list. A stale entry would not be fatal in any case --
/// glibc's spawn ignores a close failure for an in-range descriptor, and musl
/// ignores it outright -- but a shorter list is a cheaper spawn.
func openDescriptorsAboveStderr() -> [Int32] {
    var candidates: [Int32] = []
    let listings = ["/proc/self/fd", "/dev/fd"]
    for path in listings {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
        candidates = names.compactMap(Int32.init).filter { $0 > STDERR_FILENO }
        break
    }
    if candidates.isEmpty {
        let reported = sysconf(Int32(_SC_OPEN_MAX))
        let ceiling = Int32(min(max(reported, 1024), 4096))
        candidates = Array((STDERR_FILENO + 1)..<ceiling)
    }
    return candidates.filter { fcntl($0, F_GETFD) >= 0 }.sorted()
}

/// `posix_spawn` driven directly, because Foundation's `Process` exposes no hook
/// for spawn attributes and we need `POSIX_SPAWN_SETPGROUP`.
///
/// (The obvious alternative, launching via `setsid`, is not portable: macOS ships
/// no `/usr/bin/setsid`, so the child would share *our* process group and
/// `kill(-pgid)` would signal the wrong tree.)
public enum POSIXSpawn {
    /// How many times a spawn that failed with ETXTBSY -- and ONLY ETXTBSY --
    /// is retried, and how long to wait between attempts. The product is the
    /// whole extra latency this can ever add to a launch (250 ms), and it is
    /// only ever paid on Linux and only when the exec was actually refused.
    /// Small enough that a genuinely stuck writer still surfaces as a launch
    /// failure with the real errno rather than as an unexplained hang.
    static let etxtbsyMaxRetries = 10
    static let etxtbsyRetryInterval: TimeInterval = 0.025

    public static func spawn(
        executable: URL,
        args: [String],
        cwd: URL,
        env: [String: String]?,
        closing: InheritedDescriptorClosing = .platformDefault
    ) throws -> SpawnedChild {
        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { throw SpawnError.pipeFailed(errno) }
        guard pipe(&errFDs) == 0 else {
            let code = errno
            close(outFDs[0]); close(outFDs[1])
            throw SpawnError.pipeFailed(code)
        }

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        // Every one of these setup calls returns an errno, and a silent failure here
        // is worse than a loud one. `addchdir_np` is the dangerous case: if it fails
        // (ENAMETOOLONG on a long path, EINVAL, ENOSYS on another libc) the spawn
        // still succeeds and the child runs in the *harness's* cwd — a benchmark
        // measuring the wrong source tree. We record the first failure and refuse to
        // spawn rather than measure something we cannot name.
        var setupFailure: (call: String, code: Int32)?
        func checked(_ call: String, _ code: Int32) {
            if code != 0 && setupFailure == nil { setupFailure = (call, code) }
        }

        // The child becomes its own process-group leader *before* exec, so every
        // descendant it forks lands in that same group and `kill(-pgid)` reaches
        // all of them. This works identically on macOS and Linux.
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        checked("posix_spawnattr_setpgroup", posix_spawnattr_setpgroup(&attr, 0))

        // Reset inherited signal state. We must not hand the child an ignored
        // SIGPIPE (the Swift runtime ignores it): a `yes | head` pipeline whose
        // head has exited would then spin on EPIPE forever instead of dying.
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        checked("posix_spawnattr_setsigdefault", posix_spawnattr_setsigdefault(&attr, &defaulted))
        flags |= Int16(POSIX_SPAWN_SETSIGDEF)

        var empty = sigset_t()
        sigemptyset(&empty)
        checked("posix_spawnattr_setsigmask", posix_spawnattr_setsigmask(&attr, &empty))
        flags |= Int16(POSIX_SPAWN_SETSIGMASK)

        // NOTE: `posix_spawnattr_setflags` is deliberately NOT called here --
        // the descriptor-hygiene branch further down adds one more flag on
        // Darwin, so installing `flags` before that point would silently drop
        // it. It is installed once, after that branch.

        // stdin from /dev/null: a measurement child must never block reading our
        // terminal, and must never steal keystrokes from the harness.
        checked(
            "posix_spawn_file_actions_addopen(stdin, /dev/null)",
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        )
        checked(
            "posix_spawn_file_actions_adddup2(stdout)",
            posix_spawn_file_actions_adddup2(&fileActions, outFDs[1], STDOUT_FILENO)
        )
        checked(
            "posix_spawn_file_actions_adddup2(stderr)",
            posix_spawn_file_actions_adddup2(&fileActions, errFDs[1], STDERR_FILENO)
        )
        // THE CHILD MUST INHERIT NOTHING ABOVE fd 2. Closing only OUR four pipe
        // ends is not enough, and the gap is not cosmetic: `posix_spawn` forks,
        // and the fork inherits EVERY descriptor this process has open at that
        // instant that is not marked close-on-exec -- including a descriptor
        // another thread opened for WRITING a moment earlier.
        //
        // On Linux that is a functional bug, not just untidiness. The kernel
        // enforces ETXTBSY: `execve` of a file that any process holds open for
        // writing fails with "Text file busy". So a child spawned while some
        // other thread happens to be writing `.build/release/BenchmarkTool`
        // keeps a writable descriptor to that inode for its whole lifetime, and
        // the NEXT spawn of that binary -- the measurement itself -- fails to
        // launch. `String.write(to:atomically:)` does not save us: it writes a
        // temporary file and renames it over the target, so the leaked
        // descriptor points at the very inode the path now names. Darwin does
        // not enforce ETXTBSY, which is exactly why this was invisible until
        // the package was run on Linux.
        //
        // Every branch below expresses the same intent -- "the child gets fd
        // 0/1/2 and nothing else" -- through whichever mechanism this platform
        // and this libc actually provide. The explicit file actions above are
        // still honoured: they are applied in order, before any closefrom, and
        // CLOEXEC_DEFAULT is an exec-time property that leaves file-action
        // processing alone.
        #if canImport(Darwin)
        // Darwin has had CLOEXEC_DEFAULT since 10.7, so `.platformDefault` is
        // the only case that exists here and there is nothing to fall back to.
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        var closedByCloseFrom = false
        if case .platformDefault = closing, let addCloseFrom = resolvedAddCloseFrom {
            checked(
                "posix_spawn_file_actions_addclosefrom_np(\(STDERR_FILENO + 1))",
                addCloseFrom(&fileActions, STDERR_FILENO + 1)
            )
            closedByCloseFrom = true
        }
        if !closedByCloseFrom {
            // glibc older than 2.34 (Ubuntu 20.04, Debian 11, RHEL 8), or an
            // operator who asked for this path. One close action per
            // descriptor that is open at this instant, taken as late as the
            // file-action list allows so the snapshot is as fresh as possible.
            for fd in openDescriptorsAboveStderr() {
                checked(
                    "posix_spawn_file_actions_addclose(\(fd))",
                    posix_spawn_file_actions_addclose(&fileActions, fd)
                )
            }
        }
        #endif
        // `setflags` is called AFTER the platform branch above so a flag added
        // there is actually in `flags` when it is installed.
        checked("posix_spawnattr_setflags", posix_spawnattr_setflags(&attr, flags))
        checked(
            "posix_spawn_file_actions_addchdir_np(\(cwd.path))",
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd.path)
        )

        if let failure = setupFailure {
            close(outFDs[0]); close(outFDs[1])
            close(errFDs[0]); close(errFDs[1])
            throw SpawnError.setupFailed(call: failure.call, code: failure.code)
        }

        let argv = [executable.path] + args
        let environment = env ?? ProcessInfo.processInfo.environment
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        var rc: Int32 = 0
        var etxtbsyAttempts = 0
        while true {
            rc = withCStringArray(argv) { cArgv in
                withCStringArray(envp) { cEnvp in
                    posix_spawn(&pid, executable.path, &fileActions, &attr, cArgv, cEnvp)
                }
            }
            // ETXTBSY ONLY, and bounded. The closefrom/CLOEXEC_DEFAULT above
            // removes THIS process as a source of the writable descriptor that
            // makes Linux refuse the exec, but it cannot remove every source:
            // `swift build` itself, an editor, or an indexer may still hold the
            // freshly linked binary open for a few milliseconds after the build
            // command exits, and build-then-immediately-exec is exactly what
            // the measurement pipeline does. This waits that window out.
            //
            // It is deliberately NOT a general spawn retry. ENOENT, EACCES and
            // ENOEXEC are real, permanent answers about the binary we were
            // asked to run, and retrying them would turn a clear failure into a
            // slow, confusing one. Anything other than ETXTBSY still fails on
            // the first attempt, exactly as before.
            guard rc == ETXTBSY, etxtbsyAttempts < etxtbsyMaxRetries else { break }
            etxtbsyAttempts += 1
            Thread.sleep(forTimeInterval: etxtbsyRetryInterval)
        }

        // The parent keeps only the read ends; holding a write end open would mean
        // the reader never sees EOF.
        close(outFDs[1])
        close(errFDs[1])

        guard rc == 0 else {
            close(outFDs[0])
            close(errFDs[0])
            // posix_spawn returns the error code, it does not set errno.
            throw SpawnError.spawnFailed(path: executable.path, code: rc)
        }

        return SpawnedChild(pid: pid, stdoutFD: outFDs[0], stderrFD: errFDs[0])
    }
}

/// Builds a NULL-terminated `char *[]` that stays valid for the duration of `body`.
private func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

#endif

public enum Platform {
    #if canImport(Darwin) || os(Linux)
    public static let processTree: any ProcessTreeKilling = POSIXProcessTree()
    #endif
}
