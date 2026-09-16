import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: everything, including the read-only guarantee, lives in
/// `StatusRunner.describe(repo:tag:env:)`. This command only wires CLI
/// options to it and prints the result.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report on a run without changing it."
    )

    @OptionGroup var repoOption: RepoOption

    @Option(name: .long, help: "The run to report on.")
    var tag: String

    func run() throws {
        print(try StatusRunner.describe(
            repo: repoOption.repoURL, tag: tag, env: ProcessInfo.processInfo.environment))
    }
}
