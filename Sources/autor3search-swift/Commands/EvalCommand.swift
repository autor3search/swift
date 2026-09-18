import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: the whole gate chain, the measurement session, the scoring and
/// the baseline advance live in `EvalRunner.run(repo:env:source:now:)`. This
/// command only chooses an output format and translates the verdict into an
/// exit code.
///
/// THE ONE-OBJECT CONTRACT. In `--json` mode this is the ONLY writer of
/// stdout in the process, and it writes exactly once: no progress text, no
/// second verdict, no `print`. `AutoR3SearchKit` never writes stdout at all,
/// so a `--json` run's stdout is precisely the bytes of one JSON object.
struct EvalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Run one experiment through the gate chain, measure it, and return a verdict."
    )

    @OptionGroup var repoOption: RepoOption

    @Flag(name: .long, help: "Print exactly one JSON object on stdout and nothing else.")
    var json = false

    func run() throws {
        // BEFORE any child is spawned. `stop --force` sends SIGTERM to this
        // process; with the default disposition that kills it instantly, runs
        // no `defer`, and leaves the in-flight `swift build` / `swift test` /
        // `BenchmarkTool` orphaned to init, still burning CPU and silently
        // corrupting every later measurement on this machine. The trap kills
        // that child's whole process group first. See `SignalTrap`.
        if !SignalTrap.install() {
            FileHandle.standardError.write(Data("""
                warning: could not install the SIGTERM/SIGINT handler. `stop --force`, or Ctrl-C, \
                will leave the running build, test or benchmark process orphaned and consuming \
                CPU, which corrupts later measurements on this machine. Kill it by hand if you \
                stop this run.

                """.utf8))
        }

        let repo = repoOption.repoURL

        // Best-effort and read-only. `jsonData(config:)` uses it only to add
        // the `alpha` / `corrected_alpha` convenience fields; when the config
        // cannot be read (which is itself one of the things eval reports on)
        // those two keys are simply omitted, exactly as the Task 14 contract
        // specifies, and every fact they summarize is still present on each
        // benchmark delta.
        let config = try? Config.load(repo.appendingPathComponent(".autor3search/config.yaml"))

        let verdict: Verdict
        do {
            verdict = try EvalRunner.run(repo: repo, env: ProcessInfo.processInfo.environment)
        } catch {
            // A harness failure, categorically distinct from a failing child
            // process: a build that does not compile or a test that fails is
            // DATA and comes back as a FAIL verdict from `run` above.
            let crash = Verdict(
                kind: .crash, score: .nan, deltas: [], reason: "\(error)",
                warnings: [], unsafeHits: [], buildConfiguration: "release",
                stopRequested: false)
            try emit(crash, config: config)
            throw ExitCode(VerdictKind.crash.exitCode)
        }
        try emit(verdict, config: config)
        throw ExitCode(verdict.kind.exitCode)
    }

    private func emit(_ verdict: Verdict, config: Config?) throws {
        if json {
            FileHandle.standardOutput.write(try verdict.jsonData(config: config))
        } else {
            print(verdict.humanReport())
        }
    }
}
