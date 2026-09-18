import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: all discovery, validation and writing logic lives in
/// `InitRunner.run(repo:force:)`. This command only wires CLI options to it
/// and reports the outcome.
struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: """
            Discover benchmarks, write .autor3search/config.yaml, program.md and .gitignore \
            entries, resolve dependencies, and COMMIT .gitignore and Package.resolved.
            """,
        discussion: """
            init makes exactly one commit, containing exactly .gitignore and Package.resolved \
            (only whichever of the two is untracked or modified -- nothing is committed when both \
            are already tracked and unchanged). It stages by path and never `add -A`, so \
            unrelated staged, modified or untracked work in your tree is not swept in. The SHA \
            and the paths are printed.

            Why init commits at all: `swift build` writes Package.resolved into the package root \
            while `swift package describe` does not, so a repository without a committed lockfile \
            has its FIRST eval create one -- after which every experiment fails permanently, as \
            manifest_change_rejected if the agent commits it or dirty_working_tree if it does \
            not. baseline pins that file's hash and refuses a dirty tree, so it has to be \
            committed before the freeze either way.

            config.yaml and program.md are deliberately NOT committed: review them, adjust scope \
            if the warnings below say you should, then commit them yourself before running \
            baseline.
            """
    )

    @OptionGroup var repoOption: RepoOption

    @Flag(help: "Overwrite an existing .autor3search/config.yaml.")
    var force = false

    func run() throws {
        let outcome = try InitRunner.runReportingCommit(repo: repoOption.repoURL, force: force)
        let config = outcome.config
        print("""
        Wrote .autor3search/config.yaml, program.md and .gitignore entries
          benchmark target: \(config.benchmarkTarget)
          benchmarks: \(config.benchmarks.joined(separator: ", "))
          scope: \(config.scope.joined(separator: ", "))
        """)

        // ANNOUNCE THE COMMIT. init is the one command in this tool that
        // writes to someone else's git history, and it does so because the
        // dependency pin is meaningless unless Package.resolved exists at
        // frozenCommit. An unannounced commit in another person's repository
        // is not acceptable even when it is correct, so the SHA and the exact
        // paths are printed, along with how to undo it.
        if let commit = outcome.harnessCommit {
            print("")
            print("""
            Committed \(commit.paths.joined(separator: " and ")) as \(commit.sha)
              These have to be tracked before `baseline` freezes: swift build writes \
            Package.resolved into the package root, so an untracked one makes every eval after \
            the first fail permanently, and .gitignore must cover .build/ at frozenCommit.
              Only those path(s) were staged -- nothing else in your tree was touched.
              To undo: git reset --soft HEAD~1
            """)
        } else {
            print("")
            print("Committed nothing: .gitignore and Package.resolved were already tracked and " +
                  "unchanged.")
        }
        print("Not committed: .autor3search/config.yaml and program.md -- review them, then " +
              "commit before running `baseline`.")
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
