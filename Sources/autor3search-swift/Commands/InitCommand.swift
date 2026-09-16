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

        // Best-effort: this is an advisory check, not part of what makes `init`
        // succeed or fail. init already wrote a usable config by this point, so a
        // failure here (e.g. a transient `swift package describe` hiccup) is
        // reported but does not change init's own exit status -- the human just
        // doesn't get this particular heads-up on this run and is told so plainly
        // rather than left to think everything was checked.
        do {
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
