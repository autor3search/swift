// Sources/AutoR3SearchKit/Verdict/ResultsTSV.swift
//
// `results.tsv` is not part of the metric - it is the human's morning log of
// what an unattended agent did overnight. It never needs to be machine-
// parsed by the agent (that is `--json`'s job, see VerdictJSON.swift), but
// `report` (a later task) does read it back, and a corrupted or misaligned
// log is worse than no log: someone reads a wrong row and draws a wrong
// conclusion about what happened.
import Foundation

public struct ResultsRow: Sendable, Equatable {
    public let experiment: Int
    public let commit: String
    public let status: String
    public let score: Double
    public let reason: String
    public let unsafeCount: Int
    public let toolVersion: String
    public let timestamp: String

    public init(
        experiment: Int,
        commit: String,
        status: String,
        score: Double,
        reason: String,
        unsafeCount: Int,
        toolVersion: String,
        timestamp: String
    ) {
        self.experiment = experiment
        self.commit = commit
        self.status = status
        self.score = score
        self.reason = reason
        self.unsafeCount = unsafeCount
        self.toolVersion = toolVersion
        self.timestamp = timestamp
    }

    /// Formats `score` with a fixed `.` decimal separator regardless of the
    /// process locale. `String(format:)` without an explicit locale follows
    /// the current locale, which on a comma-decimal system would write
    /// "0,7500" - a string `ResultsTSV.read`'s locale-independent
    /// `Double.init(String)` can never parse back. This is the same
    /// `en_US_POSIX` fix applied in `Verdict.humanReport()`.
    private static let posix = Locale(identifier: "en_US_POSIX")

    var tsv: String {
        [
            String(experiment),
            ResultsTSV.escape(commit),
            ResultsTSV.escape(status),
            String(format: "%.4f", locale: Self.posix, score),
            ResultsTSV.escape(reason),
            String(unsafeCount),
            ResultsTSV.escape(toolVersion),
            ResultsTSV.escape(timestamp),
        ].joined(separator: "\t")
    }
}

public enum ResultsTSV {
    public static let header = "experiment\tcommit\tstatus\tscore\treason\tunsafe\ttool_version\ttimestamp\n"

    /// Appends `row` to `url`, writing `header` first exactly once.
    ///
    /// HEADER IDEMPOTENCE: the naive "write the header iff the file does not
    /// exist" check has a hole - a file that exists but is empty (created
    /// and never written, or truncated by something external) would then
    /// never get a header, silently producing a headerless log forever
    /// after. This checks the file's SIZE, not merely its existence: an
    /// existing-but-empty file is treated the same as a missing one and
    /// still gets exactly one header write. It cannot, by this same logic,
    /// ever write the header twice: any append that leaves at least one
    /// header's worth of bytes behind makes the file non-empty, so every
    /// later call skips straight to appending the row.
    public static func append(_ row: ResultsRow, to url: URL) throws {
        let fm = FileManager.default
        let isEmpty: Bool
        if let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int {
            isEmpty = size == 0
        } else {
            isEmpty = true // file does not exist (or is unreadable) - treat as needing a header
        }
        if isEmpty {
            try header.write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((row.tsv + "\n").utf8))
    }

    /// Parses every data row `append` wrote (the header line is skipped).
    /// Uses the exact inverse of `escape` on each field, so a value that
    /// contained a tab, newline, carriage return, or backslash when written
    /// comes back byte-for-byte identical, not truncated or shifted into the
    /// wrong column.
    public static func read(_ url: URL) throws -> [ResultsRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().compactMap { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 8,
                  let experiment = Int(columns[0]),
                  let score = Double(columns[3]),
                  let unsafeCount = Int(columns[5])
            else { return nil }
            return ResultsRow(
                experiment: experiment,
                commit: unescape(columns[1]),
                status: unescape(columns[2]),
                score: score,
                reason: unescape(columns[4]),
                unsafeCount: unsafeCount,
                toolVersion: unescape(columns[6]),
                timestamp: unescape(columns[7])
            )
        }
    }

    // MARK: - TSV injection

    // TSV INJECTION: `commit`, `status`, `reason`, `toolVersion`, and
    // `timestamp` are all plain strings, and at least one of them
    // (`reason`) is not a fixed, tool-chosen enum in every call site the
    // agent can reach - and the agent fully controls other inputs (branch
    // names, file paths that could end up embedded in a message) that might
    // one day flow into a string field here. A raw tab in any field shifts
    // every column after it; a raw newline forges what looks like an
    // entirely new, well-formed row (with only 1-2 real columns) in the
    // middle of the file - both corrupt the log a human reads, and the
    // second is an actual injection, not just misalignment. Rather than
    // reject such values (adds a failure mode to a code path that must
    // never lose an overnight result) or silently strip them (destroys
    // information), every string field is escaped on write and unescaped on
    // read: backslash becomes `\\`, tab becomes `\t`, LF becomes `\n`, CR
    // becomes `\r`. This is reversible and keeps the file at exactly one
    // physical line per row, so `read`'s `split(separator: "\n")` and
    // `split(separator: "\t")` can never be fooled by row content.
    fileprivate static func escape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else {
                out.append(ch)
                continue
            }
            switch next {
            case "\\": out.append("\\")
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "r": out.append("\r")
            default:
                // Not an escape sequence this writer produces (e.g. a lone
                // backslash from data written by something else). Keep both
                // characters rather than silently dropping the backslash.
                out.append(ch)
                out.append(next)
            }
        }
        return out
    }
}
