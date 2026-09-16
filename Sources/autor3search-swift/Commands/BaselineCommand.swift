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
