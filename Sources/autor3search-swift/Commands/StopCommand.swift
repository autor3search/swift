import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: `StopRunner` and `StopRequest` own the actual logic,
/// including the signaling judgment call `--force` makes. This command only
/// wires CLI options to them and prints an honest account of what happened.
struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Ask a run to exit gracefully after its current experiment is scored."
    )

    @OptionGroup var repoOption: RepoOption

    @Option(name: .long, help: "The run to stop.")
    var tag: String

    @Flag(name: .long, help: "Cancel a pending stop request instead of making one.")
    var clear = false

    @Flag(name: .long, help: """
        Also make a best-effort attempt to abandon the experiment already in flight, by \
        signaling the eval process holding this run's claim (same host only; see the printed \
        note on what this does not do).
        """)
    var force = false

    func run() throws {
        let env = ProcessInfo.processInfo.environment
        let repo = repoOption.repoURL

        if clear {
            _ = try StopRunner.clear(repo: repo, tag: tag, env: env)
            print("stop request for tag \"\(tag)\" cleared (if one was pending).")
            return
        }

        if force {
            let outcome = try StopRunner.force(repo: repo, tag: tag, env: env)
            print("stop requested for tag \"\(tag)\".")
            switch outcome.forceResult {
            case .signaled(let pid):
                print("""
                    a live eval (pid \(pid), this host) was signaled (SIGTERM) to abandon its \
                    in-flight experiment now. NOTE: this does not and cannot kill any build or \
                    benchmark subprocess that eval already spawned -- those run in a separate \
                    process group by design, and nothing here reaches into it. Check for \
                    orphaned processes if that matters to you.
                    """)
            case .noEvalInFlight:
                print("""
                    no eval currently holds this run's claim -- there is nothing in flight to \
                    abandon. The stop request has still been written and will be honored by \
                    the next eval.
                    """)
            case .remoteHolder(let host):
                print("""
                    this run's claim is currently held by a process on host "\(host)", not this \
                    machine -- refusing to signal a process this tool cannot safely identify \
                    from here. The stop request was still written and will be honored when that \
                    eval next reports a verdict; stop it directly on \(host) if you need its \
                    current experiment abandoned immediately.
                    """)
            case .unparseablePID:
                print("""
                    a live eval holds this run's claim but its recorded pid could not be parsed \
                    -- refusing to guess and signal the wrong process. The stop request was \
                    still written and will be honored when it next reports a verdict.
                    """)
            case .none:
                break
            }
            return
        }

        _ = try StopRunner.request(repo: repo, tag: tag, env: env)
        print("""
            stop requested for tag \"\(tag)\". The experiment already in flight (if any) will \
            still finish and be scored, and its KEEP or DISCARD applied as normal; the agent's \
            loop is expected to exit once that verdict reports stop_requested. Nothing in \
            flight is thrown away.
            """)
    }
}
