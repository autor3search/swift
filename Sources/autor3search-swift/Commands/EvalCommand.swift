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
