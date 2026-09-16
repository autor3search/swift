// Sources/AutoR3SearchKit/Commands/ReportRunner.swift
//
// `report` summarizes `results.tsv` -- the human's morning log of what an
// unattended agent did overnight (see `ResultsTSV`). `results.tsv` lives at
// the repository's root (written there by `EvalRunner.run`, one file shared
// by every run on that repository, not scoped under `StateHome` by tag), so
// unlike `StatusRunner` and `StopRequest` this type needs no `StateHome`,
// `tag`, or `env` at all -- it operates purely on the rows the file already
// contains.
import Foundation

public struct ReportSummary: Sendable {
    public let counts: [String: Int]
    public let cumulativeSpeedup: Double
    public let largestWins: [ResultsRow]
    public let unsafeCommits: [Int]
}

/// What `ReportRunner.load(from:)` found, beyond the rows themselves.
///
/// Not part of `ReportSummary` (that shape is fixed -- later tasks depend on
/// exactly those four fields). This is a separate, additive result so the
/// CLI can be honest about a partially unreadable log without changing the
/// summary's contract.
public struct ReportLoadResult: Sendable {
    public let rows: [ResultsRow]

    /// Data rows physically present in the file that `ResultsTSV.read`
    /// silently dropped because they were malformed (too few columns, or an
    /// unparseable experiment number, score, or unsafe count -- see
    /// `ResultsTSV.read`'s doc comment: it skips a bad row rather than
    /// throwing, because losing the ENTIRE log to one corrupted line would
    /// be worse than losing one line). `read` alone gives no way to tell
    /// "12 experiments happened" from "12 experiments happened and 3 more
    /// were logged but are now unreadable" -- a report that quietly comes up
    /// short of what actually ran is a silent lie. This is computed by
    /// comparing against a raw physical-line count, using exactly the same
    /// splitting rule `read` itself uses (one physical line per row is an
    /// invariant `ResultsTSV.append`'s escaping guarantees for every row
    /// this tool ever wrote -- see its "TSV INJECTION" note).
    public let skippedRowCount: Int
}

public enum ReportRunner {
    /// Cumulative speedup is the PRODUCT of every KEPT score, not the
    /// latest one. This is a direct consequence of the measurement baseline
    /// advancing on every KEEP (see `BaselineRecord.measurementCommit` and
    /// `EvalRunner`'s baseline-advance note): each kept score is only that
    /// experiment's own incremental contribution over what was *just* kept,
    /// not over the run's original starting point, so successive real
    /// improvements compound the way successive percentage changes do
    /// (a 2x win followed by another 2x win is 4x overall, not "still 2x").
    /// A DISCARD contributes nothing -- it was reset away and never became
    /// the new measurement point.
    ///
    /// The product of zero kept scores is `1.0` -- mathematically exact
    /// ("no change from baseline"), but this is a library-level fact, not a
    /// human-facing string: `ReportCommand` special-cases a zero-keep run
    /// rather than printing "1.00x" as though a comparison had actually
    /// been made.
    public static func summarize(_ rows: [ResultsRow]) -> ReportSummary {
        var counts: [String: Int] = [:]
        for r in rows { counts[r.status, default: 0] += 1 }
        let kept = rows.filter { $0.status == "keep" }
        let product = kept.reduce(1.0) { $0 * $1.score }
        return ReportSummary(
            counts: counts,
            cumulativeSpeedup: product,
            largestWins: kept.sorted { $0.score < $1.score }.prefix(5).map { $0 },
            unsafeCommits: kept.filter { $0.unsafeCount > 0 }.map(\.experiment))
    }

    /// Reads `results.tsv` at `url` and separately reports how many data
    /// rows `ResultsTSV.read` silently dropped as malformed.
    public static func load(from url: URL) throws -> ReportLoadResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        let dataLineCount = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .count
        let rows = try ResultsTSV.read(url)
        return ReportLoadResult(rows: rows, skippedRowCount: max(0, dataLineCount - rows.count))
    }
}
