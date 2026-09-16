// Sources/AutoR3SearchKit/Commands/StopRunner.swift
//
// `stop` is how a human ends a run gracefully. The marker file itself is
// `StopRequest`'s job; this type is the thin orchestration `StopCommand`
// calls into, and -- for `--force` -- the one place that reasons about
// signaling a process this tool does not own.
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What `stop` actually did, so the CLI can report it honestly rather than
/// claim an action that did not happen. See `StopRunner.force`'s doc
/// comment for why `--force` can genuinely come back having signaled
/// nothing.
public struct StopOutcome: Sendable, Equatable {
    public let tag: String
    public let requestWritten: Bool
    public let cleared: Bool
    /// `nil` unless `--force` was requested.
    public let forceResult: ForceResult?

    public enum ForceResult: Sendable, Equatable {
        /// A live eval was found on THIS host and SIGTERM was sent to it.
        case signaled(pid: Int32)
        /// No live eval currently holds this run's claim -- nothing to abandon.
        case noEvalInFlight
        /// A live eval holds the claim, but its recorded host is not this
        /// machine. Signaling a pid recorded by a different machine would
        /// not even resolve to the right process here, so this deliberately
        /// signals nothing.
        case remoteHolder(host: String)
        /// A live eval holds the claim on this host, but its recorded pid
        /// could not be parsed out of the claim body -- refuses to guess.
        case unparseablePID
    }
}

public enum StopRunner {
    public static func request(repo: URL, tag: String, env: [String: String]) throws -> StopOutcome {
        let home = try StateHome(repo: repo, env: env)
        try StopRequest.request(home: home, tag: tag)
        return StopOutcome(tag: tag, requestWritten: true, cleared: false, forceResult: nil)
    }

    public static func clear(repo: URL, tag: String, env: [String: String]) throws -> StopOutcome {
        let home = try StateHome(repo: repo, env: env)
        try StopRequest.clear(home: home, tag: tag)
        return StopOutcome(tag: tag, requestWritten: false, cleared: true, forceResult: nil)
    }

    /// Writes the stop request -- exactly as `request` does -- and
    /// additionally makes a best-effort attempt to abandon the experiment
    /// already in flight, by signaling the process holding this run's claim.
    ///
    /// SAFETY. `RunClaim` is an flock: it proves *some* live process holds
    /// it, but the only way to learn WHICH one is the free-text body that
    /// process wrote into the claim file at acquire time (`pid=... host=...
    /// started=... tool=...`, see `RunClaim.acquire`) -- the lock itself
    /// carries no pid. This signals that recorded pid ONLY when:
    ///   1. the claim is held RIGHT NOW (checked twice: once before parsing
    ///      the body, once again immediately before signaling, to keep the
    ///      unavoidable race window as small as this call can make it), and
    ///   2. the recorded host matches this machine's own hostname.
    /// (2) matters beyond the obvious "can't signal a remote pid": `RunClaim`
    /// itself documents that `flock` is unreliable over a network
    /// filesystem, which is exactly the situation in which a state home
    /// could be shared across machines and the recorded host could be
    /// wrong. A host mismatch is reported, never signaled.
    ///
    /// RESIDUAL RISK, STATED PLAINLY, NOT HIDDEN. Between the second
    /// liveness check and the `kill()` call, the holder could still die and
    /// its pid be reused by an unrelated process on this same host -- an
    /// inherent property of pid-based signaling that no re-check eliminates,
    /// only shrinks. This is the same class of window `RunClaim.isHeld`
    /// itself already accepts as correct (see its doc comment: "no window
    /// ... longer than one syscall pair"); this call cannot do better than
    /// that, only add one more small window on top. SIGTERM, not SIGKILL, is
    /// used so a process that turns out not to be the intended eval still
    /// has the chance to handle or ignore it.
    ///
    /// WHAT ACTUALLY HAPPENS TO THE IN-FLIGHT CHILD, STATED PLAINLY: `eval`
    /// traps SIGTERM (and SIGINT) and, before exiting, kills the in-flight
    /// child's whole process GROUP -- see `SignalTrap` -- including
    /// grandchildren that stay in it. A `swift build`, `swift test` or
    /// `BenchmarkTool` running at the moment of the signal is killed with
    /// it, not merely orphaned; this was previously a real gap (mistake #4
    /// from this project's founding constraints, arriving through the stop
    /// path) and is now closed, with mutation evidence in `docs/run-log.md`.
    /// This signal call itself only reaches the top-level `eval` process --
    /// it is `eval`'s own installed handler, not this function, that reaches
    /// the child.
    ///
    /// ONE RESIDUAL HOLE, ALSO STATED PLAINLY, AND NOT SPECIFIC TO
    /// `--force`: a descendant that puts itself into a NEW process group at
    /// spawn escapes `kill(-pgid)` by construction. SwiftPM's
    /// `swiftpm-testing-helper` does exactly this -- observed already in its
    /// own group before any kill could reach it -- and the identical hole
    /// exists on the timeout path, which kills the same way. It is a
    /// property of the group-kill mechanism itself, not of forcing a stop.
    /// `StopCommand` states both of the above -- what is now killed, and
    /// this one residual hole -- every time a signal is actually sent.
    ///
    /// If the claim is not currently held, or its holder is a different
    /// host, or its pid cannot be parsed, this does NOT pretend to have
    /// abandoned anything -- it signals nothing and says so via the
    /// returned `ForceResult`. The stop request itself is still written in
    /// every case.
    public static func force(repo: URL, tag: String, env: [String: String]) throws -> StopOutcome {
        let home = try StateHome(repo: repo, env: env)
        try StopRequest.request(home: home, tag: tag)

        let claimURL = try home.runClaimURL(tag: tag)
        guard RunClaim.isHeld(at: claimURL) else {
            return StopOutcome(tag: tag, requestWritten: true, cleared: false, forceResult: .noEvalInFlight)
        }

        let body = (try? String(contentsOf: claimURL, encoding: .utf8)) ?? ""
        let fields = parseClaimBody(body)
        let localHost = ProcessInfo.processInfo.hostName
        guard let host = fields["host"], host == localHost else {
            return StopOutcome(
                tag: tag, requestWritten: true, cleared: false,
                forceResult: .remoteHolder(host: fields["host"] ?? "(unknown -- claim body unreadable)"))
        }
        guard let pidString = fields["pid"], let pid = Int32(pidString), pid > 0 else {
            return StopOutcome(tag: tag, requestWritten: true, cleared: false, forceResult: .unparseablePID)
        }

        // Re-check immediately before signaling; see the doc comment above.
        guard RunClaim.isHeld(at: claimURL) else {
            return StopOutcome(tag: tag, requestWritten: true, cleared: false, forceResult: .noEvalInFlight)
        }

        #if canImport(Darwin) || os(Linux)
        kill(pid, SIGTERM)
        #endif
        return StopOutcome(tag: tag, requestWritten: true, cleared: false, forceResult: .signaled(pid: pid))
    }

    private static func parseClaimBody(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for token in body.split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            out[String(token[token.startIndex..<eq])] = String(token[token.index(after: eq)...])
        }
        return out
    }
}
