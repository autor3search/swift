import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: all discovery, validation and writing logic lives in
/// `InitRunner.run(repo:force:)`. This command only wires CLI options to it
/// and reports the outcome.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Discover benchmarks and write .autor3search/config.yaml and program.md."
    )

    @OptionGroup var repoOption: RepoOption

    @Flag(help: "Overwrite an existing .autor3search/config.yaml.")
    var force = false

    func run() throws {
        let config = try InitRunner.run(repo: repoOption.repoURL, force: force)
        print("""
        Wrote .autor3search/config.yaml and program.md
          benchmark target: \(config.benchmarkTarget)
          benchmarks: \(config.benchmarks.joined(separator: ", "))
          scope: \(config.scope.joined(separator: ", "))
        """)
        if let warning = config.keepReachabilityWarning() {
            print("warning: \(warning)")
        }
    }
}
