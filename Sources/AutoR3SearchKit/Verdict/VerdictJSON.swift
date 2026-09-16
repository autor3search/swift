// Sources/AutoR3SearchKit/Verdict/VerdictJSON.swift
//
// `--json` is the AI agent's ONLY channel: it parses exactly one JSON object
// from stdout to decide whether to keep its commit or `git reset --hard
// HEAD~1`. Two contracts follow from that:
//
// 1. THE ONE-OBJECT CONTRACT. `jsonData()` never prints or writes anything
//    itself - it only returns `Data`. Nothing in this file, or anywhere else
//    in AutoR3SearchKit, may call `print(...)` (which targets stdout); any
//    diagnostic text this library produces must go to stderr. The executable
//    target (Task 17) is the ONLY writer of stdout in `--json` mode, and it
//    must write these exact bytes exactly once - `FileHandle.standardOutput
//    .write(try verdict.jsonData())` and nothing else on that code path (no
//    extra `print`, no progress text, no second verdict). `humanReport()`'s
//    output is for the non-`--json` path only; the two must never both reach
//    stdout in the same invocation.
//
// 2. NaN / Infinity. `score` is `.nan` for an empty-samples run, and a
//    `BenchmarkDelta.ratio` is `+inf` when a baseline median measures 0.
//    JSON itself has no NaN/Infinity literal, and `JSONEncoder` THROWS by
//    default on a non-conforming float - which, for this payload, would mean
//    `eval` produces NO json at all on exactly the runs most worth reporting
//    (a `no_measurements` discard, or a baseline that measured zero). Three
//    options were on the table: throw (breaks the agent's loop on the runs
//    that most need a verdict - rejected), substitute 0 (indistinguishable
//    from a real 0.0 ratio/score - a lie, rejected per the task ruling), or
//    represent the value as a string token via
//    `nonConformingFloatEncodingStrategy`. This file uses the third: NaN and
//    +/-Infinity encode as the strings "NaN", "Infinity", "-Infinity" -
//    self-documenting, round-trippable by any consumer that checks for them,
//    and - critically - the encode call still succeeds, so a verdict with a
//    NaN score still produces exactly one valid JSON object on stdout.
import Foundation

extension Verdict {
    private struct Payload: Encodable {
        let verdict: String
        let exit_code: Int32
        let score: Double
        let reason: String?
        let warnings: [String]
        let unsafeHits: [UnsafeHit]
        let benchmarks: [BenchmarkDelta]
        let build_configuration: String
        let stop_requested: Bool

        // k = the number of benchmarks actually measured in this verdict
        // (`deltas.count`). Unlike `Scoring.keepAlpha(config:)` - which
        // divides by the DECLARED benchmark count - this is read straight
        // off the verdict itself, so it cannot desync from what `decide`
        // actually corrected against.
        let k: Int

        // alpha / corrected_alpha: present only when the caller supplies a
        // `Config` to `jsonData(config:)` (see below). When present,
        // `corrected_alpha` is computed as `config.alpha / max(k, 1)` using
        // THIS verdict's own `k`, not `config.benchmarks.count` - byte-
        // identical to the correction `Scoring.decide` actually applied, by
        // construction. Per-benchmark `significantAtAlpha` /
        // `significantAtCorrected` on each `BenchmarkDelta` are the
        // authoritative, always-present facts; these two scalars are a
        // convenience for a consumer that wants "the" threshold without
        // recomputing it, and are deliberately omitted (not defaulted to a
        // guess) when no config was given.
        let alpha: Double?
        let corrected_alpha: Double?

        enum CodingKeys: String, CodingKey {
            case verdict, exit_code, score, reason, warnings, benchmarks, k, alpha
            case unsafeHits = "unsafe"
            case build_configuration, stop_requested, corrected_alpha
        }
    }

    /// Encodes this verdict as the single JSON object `--json` prints on
    /// stdout. Never throws on NaN/Infinity (see the file-level comment);
    /// the only realistic throw source left is a future encoder misuse.
    ///
    /// - Parameter config: optional. When supplied, the payload additionally
    ///   carries `alpha` (`config.alpha`, uncorrected) and `corrected_alpha`
    ///   (`config.alpha / max(deltas.count, 1)`) - derived from THIS
    ///   verdict's measured benchmark count, never from
    ///   `config.benchmarks.count`. See the ruling in the file header:
    ///   emitting `Scoring.keepAlpha(config:)` here would be a lie whenever
    ///   fewer benchmarks were measured than declared, because it divides by
    ///   the wrong (larger) k and so advertises a stricter bar than was
    ///   actually applied. Omitting `config` (the default, and what the
    ///   fixed `jsonData()` call sites in Tasks 17/18 use) simply omits
    ///   these two convenience fields; every fact they would summarize is
    ///   already present, unambiguously, on each `BenchmarkDelta`.
    public func jsonData(config: Config? = nil) throws -> Data {
        let k = deltas.count
        let payload = Payload(
            verdict: kind.rawValue,
            exit_code: kind.exitCode,
            score: score,
            reason: reason,
            warnings: warnings,
            unsafeHits: unsafeHits,
            benchmarks: deltas,
            build_configuration: buildConfiguration,
            stop_requested: stopRequested,
            k: k,
            alpha: config?.alpha,
            corrected_alpha: config.map { $0.alpha / Double(max(k, 1)) }
        )
        let encoder = JSONEncoder()
        // No pretty printing: the contract is one object on one line, not a
        // multi-line rendering that some naive stdout scraper might split.
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return try encoder.encode(payload)
    }

    /// Appends a warning when fewer (or more) benchmarks were actually
    /// measured than `config` declares - a partial measurement worth
    /// surfacing to the human regardless of which alpha applied. `Verdict`
    /// does not carry its originating `Config`, so this cannot live inside
    /// `Scoring.decide` (frozen, Task 13) or inside the fixed, zero-argument
    /// `jsonData()`/`humanReport()` (Tasks 17/18 call sites) - the intended
    /// use is for the orchestrator (Task 17), which has both the `Verdict`
    /// and the `Config` it came from, to call this once, immediately after
    /// `Scoring.decide`, before handing the result to `jsonData()` and
    /// `humanReport()`. Because it returns a new `Verdict` with the warning
    /// folded into `warnings`, it surfaces identically in both outputs
    /// without either method needing a `config` parameter.
    public func addingPartialMeasurementWarning(config: Config) -> Verdict {
        guard deltas.count != config.benchmarks.count else { return self }
        let message = "partial measurement: \(deltas.count) of \(config.benchmarks.count) declared benchmark(s) were measured"
        return Verdict(
            kind: kind, score: score, deltas: deltas, reason: reason,
            warnings: warnings + [message], unsafeHits: unsafeHits,
            buildConfiguration: buildConfiguration, stopRequested: stopRequested
        )
    }

    /// The human-readable report for the non-`--json` path. Must never be
    /// written to stdout in the same invocation that also writes
    /// `jsonData()`'s bytes there - see the file-level comment.
    public func humanReport() -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        var lines: [String] = []
        for w in warnings { lines.append("WARNING: \(w)") }
        if !unsafeHits.isEmpty {
            lines.append("UNSAFE: this commit introduces \(unsafeHits.count) unsafe construct(s)")
            for h in unsafeHits { lines.append("  \(h.file):\(h.line)  \(h.construct)") }
            lines.append("  frozen tests verify behavior, not the absence of UB. review before merging.")
        }
        for d in deltas {
            var note = ""
            // significantAtAlpha but not significantAtCorrected must never be
            // relabelled "not significant" - it IS significant at the plain
            // alpha a reader expects; it only failed the stricter, KEEP-
            // specific Bonferroni bar. "did not clear" says exactly that.
            if d.significantAtAlpha && !d.significantAtCorrected {
                note = "  (significant at alpha, did not clear the Bonferroni-corrected threshold)"
            }
            lines.append(String(
                format: "  %@  %.0f -> %.0f ns  ratio %.4f  p=%.5f%@",
                locale: posix,
                d.benchmark, d.baselineMedian, d.candidateMedian, d.ratio, d.pValue, note
            ))
        }
        lines.append("measured from a \(buildConfiguration) build")
        lines.append("VERDICT: \(kind.rawValue.uppercased())" + (reason.map { "  (\($0))" } ?? ""))
        return lines.joined(separator: "\n")
    }
}
