import ArgumentParser
import AutoR3SearchKit
import Foundation

/// Thin shell: all summarizing logic lives in `ReportRunner`. `results.tsv`
/// lives at the repository's root (see `ReportRunner`'s header comment), so
/// unlike `status` and `stop` this command needs no `--tag`.
struct ReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Summarize results.tsv: what an unattended run actually did."
    )

    @OptionGroup var repoOption: RepoOption

    func run() throws {
        let resultsURL = repoOption.repoURL.appendingPathComponent("results.tsv")
        guard FileManager.default.fileExists(atPath: resultsURL.path) else {
            print("no results.tsv found at \(resultsURL.path) -- nothing has been evaluated yet.")
            return
        }

        let loaded = try ReportRunner.load(from: resultsURL)
        let summary = ReportRunner.summarize(loaded.rows)

        print("Report")
        print("  experiments: \(loaded.rows.count)")
        print("    keep:    \(summary.counts["keep"] ?? 0)")
        print("    discard: \(summary.counts["discard"] ?? 0)")
        print("    fail:    \(summary.counts["fail"] ?? 0)")
        print("    crash:   \(summary.counts["crash"] ?? 0)")
        if loaded.skippedRowCount > 0 {
            print("""
                  warning: \(loaded.skippedRowCount) row(s) in results.tsv were malformed and \
                skipped -- every count above is short by that many rows.
                """)
        }

        print("")
        let keptCount = summary.counts["keep"] ?? 0
        if keptCount == 0 {
            // The PRODUCT of zero kept scores is mathematically 1.0 ("no
            // change"), but printing "1.00x" here would read as "measured,
            // and found unchanged" -- a claim this run never made, since
            // nothing was ever kept to measure a change against. Say so
            // plainly instead of printing a number a human could misread.
            print("  cumulative speedup: no experiments have been kept yet -- nothing to report.")
        } else {
            let ratio = summary.cumulativeSpeedup
            if ratio.isFinite, ratio > 0 {
                print(String(
                    format: "  cumulative speedup: %.4f of original duration (%.2fx faster)",
                    ratio, 1.0 / ratio))
            } else {
                print("  cumulative speedup: unavailable (a kept experiment has a non-finite score)")
            }
        }

        if !summary.largestWins.isEmpty {
            print("")
            print("  largest wins (kept, fastest first):")
            for row in summary.largestWins {
                print("    experiment \(row.experiment)  commit \(row.commit)  score \(String(format: "%.4f", row.score))")
            }
        }

        if !summary.unsafeCommits.isEmpty {
            print("")
            print("""
                  KEPT commits that introduced unsafe constructs (frozen tests verify behaviour, \
                but cannot catch undefined behaviour -- review these):
                """)
            for experiment in summary.unsafeCommits {
                print("    experiment \(experiment)")
            }
        }
    }
}
