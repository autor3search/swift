import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: everything that builds, spawns, attaches a sampler and reads
/// `BenchmarkTool`'s metrics lives in `Sampler` (`AutoR3SearchKit`). This
/// command only chooses which benchmarks to profile and formats the result --
/// the same division `report` uses for `ReportRunner`'s structured summary.
///
/// `-Xswiftc -g`, AND WHY IT TURNED OUT NOT TO MATTER. `Sampler.profile`
/// builds `config.benchmarkTarget` with `-Xswiftc -g` explicitly, on the
/// original theory that `eval`'s own bare `swift build -c release` might not
/// carry debug info and the extra flag would leave a rebuilt, differently-
/// keyed binary behind. MEASURED, not assumed: `swift build -c release -v`
/// already passes `-g -debug-info-format=dwarf -dwarf-version=4` with no
/// extra flags at all (this toolchain's release configuration emits debug
/// info by default), and a SHA256 of `.build/release/<target>` taken after a
/// plain `swift build -c release`, after `profile`'s `-Xswiftc -g` build, and
/// after a second plain build were BYTE-IDENTICAL across all three. So the
/// explicit flag is redundant with what SwiftPM already does -- it changes
/// nothing about the binary, there is no extra rebuild, and the binary
/// `sample` observes here is not merely equivalent-by-reasoning to the one
/// `eval`'s gate 5 measures, it is bit-for-bit the same file. Left in the
/// build invocation anyway, as explicit intent that stays correct even if a
/// future toolchain ever stops defaulting to `-g` for release builds.
struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Profile hot lines and instruction/malloc-count hints for one or more benchmarks."
    )

    @OptionGroup var repoOption: RepoOption

    @Option(name: .long, help: """
        Profile only this benchmark instead of every benchmark declared in \
        .autor3search/config.yaml.
        """)
    var benchmark: String?

    @Option(name: .long, help: "How long to let the CPU sampler run, in seconds (default: 5).")
    var seconds: Double = 5.0

    func run() throws {
        // `profile` spawns a long-running child too (the benchmark being
        // sampled), same as `eval`: a Ctrl-C must kill its whole process-group
        // tree rather than leave it orphaned and burning CPU on this machine.
        if !SignalTrap.install() {
            FileHandle.standardError.write(Data("""
                warning: could not install the SIGTERM/SIGINT handler. Ctrl-C will leave the \
                profiled benchmark process orphaned and consuming CPU; kill it by hand if you \
                interrupt this run.

                """.utf8))
        }

        let repo = repoOption.repoURL
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        let config: Config
        do {
            config = try Config.load(configURL)
        } catch {
            FileHandle.standardError.write(Data(
                "could not load \(configURL.path): \(error)\n".utf8))
            throw ExitCode(1)
        }

        let targets: [String]
        if let benchmark {
            guard config.benchmarks.contains(benchmark) else {
                FileHandle.standardError.write(Data("""
                    "\(benchmark)" is not one of the benchmarks declared in config.yaml: \
                    \(config.benchmarks.joined(separator: ", ")).

                    """.utf8))
                throw ExitCode(1)
            }
            targets = [benchmark]
        } else {
            targets = config.benchmarks
        }
        guard !targets.isEmpty else {
            print("no benchmarks declared in \(configURL.path); nothing to profile.")
            return
        }

        // State outside the repository, same as every other command: this is
        // BenchmarkTool's own baseline-storage scratch space, not a
        // meaningful "baseline" the way `eval`'s is, and it must never live
        // inside the repository under test (see `StateHome`'s header comment
        // on why nothing this tool writes for its own bookkeeping goes
        // there). Kept under a fixed "profile" tag, distinct from any real
        // run tag `baseline`/`eval` might use.
        let home = try StateHome(repo: repo, env: ProcessInfo.processInfo.environment)
        let storage = try home.benchStorageURL(tag: "profile")

        print(Sampler.inliningCaveat)
        print(Sampler.inclusiveCountsCaveat)
        print("""
            Instruction and malloc-count hints below come straight from BenchmarkTool and are a \
            HINT only -- they are never scored, the same as everywhere else in this tool.
            """)

        // MULTIPLE BENCHMARKS: profiled and reported ONE AT A TIME, each with
        // its own ranked table, never merged into a single combined ranking.
        // A merged table would silently compare samples from DIFFERENT
        // workloads against each other -- a line "hot" in one benchmark says
        // nothing about another, and ranking them together would imply a
        // relationship the data does not have.
        var anyFailure = false
        for (index, name) in targets.enumerated() {
            print("")
            print("=== \(name) (\(index + 1)/\(targets.count)) ===")

            do {
                let hot = try Sampler.profile(benchmark: name, repo: repo, config: config, seconds: seconds)
                let shown = hot.prefix(20)
                print("hot lines, ranked (top \(shown.count) of \(hot.count)):")
                for line in shown {
                    print("  \(line.samples)\t\(line.file):\(line.line)")
                }
                print("raw sampler output written to: \(Sampler.rawOutputURL(repo: repo, benchmark: name).path)")
            } catch {
                anyFailure = true
                print("could not profile hot lines for \"\(name)\": \(error)")
            }

            do {
                let hints = try Sampler.metricHints(benchmark: name, repo: repo, config: config, storage: storage)
                print("instruction / malloc-count hints (median of one BenchmarkTool run; never scored):")
                for hint in hints {
                    print("  \(hint.label): \(hint.p50)")
                }
            } catch {
                anyFailure = true
                print("could not read instruction/malloc counts for \"\(name)\": \(error)")
            }
        }

        if anyFailure { throw ExitCode(1) }
    }
}
