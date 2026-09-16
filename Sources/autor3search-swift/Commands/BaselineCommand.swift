import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: all discovery, freezing, worktree-pinning and warm-build logic
/// lives in `BaselineRunner.run(repo:tag:env:)`. This command only wires CLI
/// options to it and reports the outcome.
struct BaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline",
        abstract: "Freeze the success criteria and pin the measurement point for a run."
    )

    @OptionGroup var repoOption: RepoOption

    @Option(name: .long, help: "Names this run. Also the family-branch suffix: autor3search-swift/<tag>.")
    var tag: String

    func run() throws {
        // `stop --force` does not signal `baseline`, so the exposure here is Ctrl-C
        // only -- but a Ctrl-C'd `swift build` (24-33 seconds cold, per spec.md 2.2)
        // orphaned to init is mistake #4 verbatim, on the same machine, burning CPU
        // while corrupting the very measurements this harness exists to take. The warm
        // builds below go through the same single `Subprocess` path that publishes the
        // in-flight child's pgid, so one call is all it takes. See `SignalTrap`.
        if !SignalTrap.install() {
            FileHandle.standardError.write(Data("""
                warning: could not install the SIGTERM/SIGINT handler. Ctrl-C will leave the \
                running build orphaned and consuming CPU, which corrupts later measurements on \
                this machine. Kill it by hand if you interrupt this run.

                """.utf8))
        }

        let record = try BaselineRunner.run(
            repo: repoOption.repoURL, tag: tag, env: ProcessInfo.processInfo.environment)
        print("""
        Baseline \(record.tag) established
          frozen commit:      \(record.frozenCommit)
          measurement commit: \(record.measurementCommit)
          tool version:       \(record.toolVersion)
        """)

        // Best-effort, matching `init`: baseline freezes config.yaml's hash, so this is
        // the last moment before it a human can act on this warning -- but a failure to
        // compute it must not undo the baseline that was already successfully written.
        do {
            let config = try Config.load(repoOption.repoURL.appendingPathComponent(".autor3search/config.yaml"))
            let paths = try InitRunner.scopedBenchmarkDependencies(config: config, repo: repoOption.repoURL)
            if let warning = InitRunner.dependencyScopeWarning(paths: paths) {
                print("")
                print(warning)
            }
        } catch {
            print("")
            print("note: could not check the benchmark's declared dependencies against scope: \(error)")
        }
    }
}
