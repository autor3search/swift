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
//    (a `no_measurements` discard, or a baseline that measured zero).
//
//    FIX ROUND 1: this file originally used
//    `nonConformingFloatEncodingStrategy = .convertToString(...)`, encoding
//    NaN/Infinity as the strings "NaN"/"Infinity"/"-Infinity". Review caught
//    that this trades a throw for a TYPE CHANGE on `score` (and, since the
//    strategy fires on every Double the encoder touches, on `ratio`,
//    `baselineMedian`, `candidateMedian`, and `pValue` too): a typed
//    consumer expecting `score: Double`, or doing `json["score"] as?
//    Double`, gets `nil`/a decode failure - reintroducing the exact lie
//    (score silently reads as absent/0) that rejecting `score.isNaN ? 0 :
//    score` was meant to prevent, and doing so only on the degenerate runs
//    that most need a clean signal.
//
//    The fix: every Double field that can genuinely be non-finite (`score`
//    on `Verdict`; `baselineMedian`, `candidateMedian`, `ratio`, `pValue` on
//    each `BenchmarkDelta`) is converted to `Double?` before it ever reaches
//    the encoder, `nil` when `!value.isFinite`, and each field's `encode(to:)`
//    calls `container.encode(value, forKey:)` (not `encodeIfPresent`) so a
//    `nil` writes an explicit JSON `null` - present in the payload with the
//    correct field name, distinguishable from "field omitted", and valid in
//    a numeric field's type position for any consumer declaring `Double?`.
//    `nonConformingFloatEncodingStrategy` is no longer set at all: because
//    no non-finite Double can reach the encoder (every one was already
//    converted to `nil`/`null` upstream), the encoder's default
//    (throw-on-non-conforming-float) behavior is simply never triggered.
//    Nothing is lost by dropping the NaN-vs-Infinity distinction:
//    `reason == "no_measurements"` implies a NaN score, and a `+inf` ratio
//    can only arise from `baselineMedian == 0`, itself visible (as `null`,
//    by the same rule) on the same `BenchmarkDelta`. `kind` and `reason`
//    already carry the authoritative account; `score` and the per-benchmark
//    numbers are informational in exactly these cases.
import Foundation

private extension Double {
    /// `self` if finite, else `nil` - the single choke point that keeps a
    /// non-finite Double from ever reaching `JSONEncoder` in this file. A
    /// field built from this always encodes as a JSON number or an explicit
    /// JSON `null`, never as a string and never by throwing.
    var finiteOrNil: Double? { isFinite ? self : nil }
}

extension Verdict {
    /// Mirrors `BenchmarkDelta` (Task 13, frozen - untouched by this file)
    /// field-for-field, but represents each measured Double as `Double?`,
    /// nil when non-finite. See the file-level comment for why.
    private struct BenchmarkDeltaPayload: Encodable {
        let benchmark: String
        let baselineMedian: Double?
        let candidateMedian: Double?
        let ratio: Double?
        let pValue: Double?
        let significantAtAlpha: Bool
        let significantAtCorrected: Bool

        init(_ d: BenchmarkDelta) {
            benchmark = d.benchmark
            baselineMedian = d.baselineMedian.finiteOrNil
            candidateMedian = d.candidateMedian.finiteOrNil
            ratio = d.ratio.finiteOrNil
            pValue = d.pValue.finiteOrNil
            significantAtAlpha = d.significantAtAlpha
            significantAtCorrected = d.significantAtCorrected
        }

        // Manual encode(to:): synthesis would call `encodeIfPresent` for the
        // Optional Double fields, which OMITS the key on nil. We need the
        // opposite - an explicit `null` - so every one of these is written
        // with plain `encode(_:forKey:)`, whose behavior for an Optional
        // value is to encode `null` on `.none` (not to drop the key).
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(benchmark, forKey: .benchmark)
            try c.encode(baselineMedian, forKey: .baselineMedian)
            try c.encode(candidateMedian, forKey: .candidateMedian)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(pValue, forKey: .pValue)
            try c.encode(significantAtAlpha, forKey: .significantAtAlpha)
            try c.encode(significantAtCorrected, forKey: .significantAtCorrected)
        }

        enum CodingKeys: String, CodingKey {
            case benchmark, baselineMedian, candidateMedian, ratio, pValue
            case significantAtAlpha, significantAtCorrected
        }
    }

    private struct Payload: Encodable {
        let verdict: String
        let exitCode: Int32
        // nil (-> JSON null, never omitted - see encode(to:)) when this
        // verdict's score is non-finite (the no_measurements case).
        let score: Double?
        let reason: String?
        let warnings: [String]
        let unsafeHits: [UnsafeHit]
        let benchmarks: [BenchmarkDeltaPayload]
        let buildConfiguration: String
        let stopRequested: Bool

        // k = the number of benchmarks actually measured in this verdict
        // (`deltas.count`). Unlike `Scoring.keepAlpha(config:)` - which
        // divides by the DECLARED benchmark count - this is read straight
        // off the verdict itself, so it cannot desync from what `decide`
        // actually corrected against.
        let k: Int

        // alpha / corrected_alpha: present only when the caller supplies a
        // `Config` to `jsonData(config:)` (see below), in which case both
        // are always finite by construction (`config.alpha` is a validated
        // probability; `k` is a non-negative Int), so - unlike score/ratio/
        // baselineMedian/candidateMedian/pValue above - these two use plain
        // `encodeIfPresent`: omitted (key absent, not null) when no config
        // was given, present as an ordinary JSON number otherwise. When
        // present, `corrected_alpha` is computed as `config.alpha / max(k, 1)`
        // using THIS verdict's own `k`, not `config.benchmarks.count` -
        // byte-identical to the correction `Scoring.decide` actually
        // applied, by construction. Per-benchmark `significantAtAlpha` /
        // `significantAtCorrected` on each `BenchmarkDelta` remain the
        // authoritative, always-present facts; these two scalars are only a
        // convenience for a consumer that wants "the" threshold without
        // recomputing it.
        let alpha: Double?
        let correctedAlpha: Double?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(verdict, forKey: .verdict)
            try c.encode(exitCode, forKey: .exitCode)
            try c.encode(score, forKey: .score) // explicit null when non-finite
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encode(warnings, forKey: .warnings)
            try c.encode(unsafeHits, forKey: .unsafeHits)
            try c.encode(benchmarks, forKey: .benchmarks)
            try c.encode(buildConfiguration, forKey: .buildConfiguration)
            try c.encode(stopRequested, forKey: .stopRequested)
            try c.encode(k, forKey: .k)
            try c.encodeIfPresent(alpha, forKey: .alpha)
            try c.encodeIfPresent(correctedAlpha, forKey: .correctedAlpha)
        }

        enum CodingKeys: String, CodingKey {
            case verdict, score, reason, warnings, benchmarks, k, alpha
            case exitCode = "exit_code"
            case unsafeHits = "unsafe"
            case buildConfiguration = "build_configuration"
            case stopRequested = "stop_requested"
            case correctedAlpha = "corrected_alpha"
        }
    }

    /// Encodes this verdict as the single JSON object `--json` prints on
    /// stdout. Never throws on NaN/Infinity (see the file-level comment): a
    /// non-finite `score` or `BenchmarkDelta` field is converted to `nil`
    /// (-> JSON `null`) before the encoder ever sees it, so no non-finite
    /// float value is ever handed to `JSONEncoder`.
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
            exitCode: kind.exitCode,
            score: score.finiteOrNil,
            reason: reason,
            warnings: warnings,
            unsafeHits: unsafeHits,
            benchmarks: deltas.map(BenchmarkDeltaPayload.init),
            buildConfiguration: buildConfiguration,
            stopRequested: stopRequested,
            k: k,
            alpha: config?.alpha,
            correctedAlpha: config.map { $0.alpha / Double(max(k, 1)) }
        )
        let encoder = JSONEncoder()
        // No pretty printing: the contract is one object on one line, not a
        // multi-line rendering that some naive stdout scraper might split.
        encoder.outputFormatting = [.sortedKeys]
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
            // `p=%.3g`, not `%.5f`, for the same reason `Verdict` and
            // `ConfigValidation` were changed: a real p-value here is routinely
            // far below 1e-5 (the floor at count 10 is 1.0825e-5, and a decisive
            // win reports exactly that), and `%.5f` renders every one of them as
            // a flat `0.00000`. This is the human-readable half of the agent's
            // only reporting channel; a report that prints "p=0.00000" for every
            // result it ever produces is telling the reader nothing and looks
            // like a harness bug. `%.4f` on the ratio is kept: ratios live near
            // 1 and a fixed-point ratio is easier to scan down a column.
            lines.append(String(
                format: "  %@  %.0f -> %.0f ns  ratio %.4f  p=%.3g%@",
                locale: posix,
                d.benchmark, d.baselineMedian, d.candidateMedian, d.ratio, d.pValue, note
            ))
        }
        lines.append("measured from a \(buildConfiguration) build")
        lines.append("VERDICT: \(kind.rawValue.uppercased())" + (reason.map { "  (\($0))" } ?? ""))
        return lines.joined(separator: "\n")
    }
}
