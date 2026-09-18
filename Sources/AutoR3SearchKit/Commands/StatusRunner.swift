// Sources/AutoR3SearchKit/Commands/StatusRunner.swift
//
// `status` is how a human checks on a run an AI agent is driving
// unattended, often overnight. READ-ONLY IS A GUARANTEE, NOT AN
// IMPLEMENTATION DETAIL: checking on a run must never be able to change it.
// Every operation below is a read -- `FileManager.fileExists`,
// `Data`/`String(contentsOf:)`, `BaselineRecord.load`, `ResultsTSV.read` (via
// `ReportRunner.load`), `RunClaim.isHeld` (which itself only ever probes the
// flock and immediately releases it again -- see its own doc comment) and
// `git rev-parse` / `git status --porcelain` (read-only git plumbing, run
// only against the repository under test, never against anything inside the
// run directory). Nothing here creates a directory, writes a file, or takes
// the run claim. `StatusStopReportTests.statusNeverWritesAnything` asserts
// this directly: the run directory's listing is byte-identical before and
// after a `describe` call.
import Foundation

public enum StatusRunner {
    public static func describe(repo: URL, tag: String, env: [String: String]) throws -> String {
        let home = try StateHome(repo: repo, env: env)
        let recordURL = try home.baselineRecordURL(tag: tag)

        // NO RUN AT ALL: before `baseline` ever ran for this tag, or the tag
        // was mistyped. This is an ordinary, expected case for a human
        // checking in early or fat-fingering `--tag`, not an error -- it
        // must not crash, and (per the read-only guarantee above) merely
        // looking must not itself create the run directory that `baseline`
        // would otherwise create as its first side effect.
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return """
                no run found for tag "\(tag)".
                  looked for a baseline record at: \(recordURL.path)
                Run `autor3search-swift baseline -C \(repo.path) --tag \(tag)` to start one, \
                or check the tag for a typo.
                """
        }

        let record = try BaselineRecord.load(recordURL)
        let runDir = try home.runDir(tag: tag)

        var lines: [String] = []
        lines.append("Status for tag \"\(tag)\"")
        lines.append("  run directory:       \(runDir.path)")
        lines.append("  frozen commit:       \(record.frozenCommit)")
        lines.append("  measurement commit:  \(record.measurementCommit)")

        let git = Git(repo: repo)
        if let head = try? git.head(), let branch = try? git.currentBranch() {
            lines.append("  repo HEAD:           \(head) (branch \(branch))")
        } else {
            lines.append("  repo HEAD:           unavailable (not a readable git repository right now)")
        }

        let evalInFlight = RunClaim.isHeld(at: try home.runClaimURL(tag: tag))
        lines.append("  eval in flight:      \(evalInFlight ? "yes -- an eval currently holds this run's claim" : "no")")

        let stopPending = StopRequest.isPending(home: home, tag: tag)
        lines.append("""
              stop requested:      \(stopPending
                ? "yes -- the experiment in flight (if any) will still be scored; the agent's loop should exit after that verdict"
                : "no")
            """)

        let resultsURL = repo.appendingPathComponent("results.tsv")
        if FileManager.default.fileExists(atPath: resultsURL.path) {
            do {
                let loaded = try ReportRunner.load(from: resultsURL)
                let summary = ReportRunner.summarize(loaded.rows)
                lines.append("""
                      experiments logged:  \(loaded.rows.count) \
                    (keep \(summary.counts["keep"] ?? 0), discard \(summary.counts["discard"] ?? 0), \
                    fail \(summary.counts["fail"] ?? 0), crash \(summary.counts["crash"] ?? 0))
                    """)
                if loaded.skippedRowCount > 0 {
                    lines.append("""
                          warning:             \(loaded.skippedRowCount) row(s) in results.tsv were \
                        malformed and skipped -- the count above is short by that many
                        """)
                }
            } catch {
                lines.append("  experiments logged:  results.tsv exists but could not be read (\(error))")
            }
        } else {
            lines.append("  experiments logged:  0 (results.tsv not created yet)")
        }

        // TAINT: surfaced prominently, not left for a human to infer from a
        // stalled experiment count. A restore refusal is a security event --
        // a symlink or hard link appeared where a frozen file should be --
        // not a flake, and every eval on this run refuses with
        // `run_tainted` until a human clears it. See `RunTaint`.
        if let taint = RunTaint.pending(runDir: runDir) {
            lines.append("")
            lines.append("  *** RUN TAINTED -- REQUIRES HUMAN ATTENTION ***")
            lines.append("  A frozen-file restore was REFUSED: a symlink or hard link appeared")
            lines.append("  where a frozen file should be. This is evidence of tampering, not a")
            lines.append("  transient error. Every eval on this run will keep refusing with")
            lines.append("  \"run_tainted\" until a human investigates and clears the marker.")
            lines.append("  detail: \(taint)")
            lines.append("  clear it (after investigating) with:")
            lines.append("    rm \(RunTaint.url(runDir: runDir).path)")
        }

        return lines.joined(separator: "\n")
    }
}
