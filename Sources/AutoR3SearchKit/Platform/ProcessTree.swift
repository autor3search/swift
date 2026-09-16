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

/// `posix_spawn` driven directly, because Foundation's `Process` exposes no hook
/// for spawn attributes and we need `POSIX_SPAWN_SETPGROUP`.
///
/// (The obvious alternative, launching via `setsid`, is not portable: macOS ships
/// no `/usr/bin/setsid`, so the child would share *our* process group and
/// `kill(-pgid)` would signal the wrong tree.)
public enum POSIXSpawn {
    public static func spawn(
        executable: URL,
        args: [String],
        cwd: URL,
        env: [String: String]?
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

        checked("posix_spawnattr_setflags", posix_spawnattr_setflags(&attr, flags))

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
        // Close the inherited copies so the child holds only fd 0/1/2. Guarded on
        // `> STDERR_FILENO` so we can never close the dup2 target we just made.
        for fd in [outFDs[0], outFDs[1], errFDs[0], errFDs[1]] where fd > STDERR_FILENO {
            checked(
                "posix_spawn_file_actions_addclose(\(fd))",
                posix_spawn_file_actions_addclose(&fileActions, fd)
            )
        }
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
        let rc = withCStringArray(argv) { cArgv in
            withCStringArray(envp) { cEnvp in
                posix_spawn(&pid, executable.path, &fileActions, &attr, cArgv, cEnvp)
            }
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
