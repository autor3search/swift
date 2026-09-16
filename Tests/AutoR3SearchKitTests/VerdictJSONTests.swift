import Testing
import Foundation
@testable import AutoR3SearchKit

// The five tests below (through `resultsTSVAppendsWithAHeaderExactlyOnce`)
// are byte-identical to the task-14 brief and must stay that way; additions
// for the NaN/Infinity, one-object, TSV-injection, header-idempotence, and
// reader/writer-consistency questions follow below the marker.

private func verdict(_ kind: VerdictKind, reason: String? = nil,
                     warnings: [String] = [], hits: [UnsafeHit] = []) -> Verdict {
    Verdict(kind: kind, score: 0.75,
            deltas: [BenchmarkDelta(benchmark: "A", baselineMedian: 100, candidateMedian: 75,
                                    ratio: 0.75, pValue: 0.001,
                                    significantAtAlpha: true, significantAtCorrected: true)],
            reason: reason, warnings: warnings, unsafeHits: hits,
            buildConfiguration: "release", stopRequested: false)
}

@Test func jsonIsExactlyOneObject() throws {
    let data = try verdict(.keep).jsonData()
    let obj = try JSONSerialization.jsonObject(with: data)
    #expect(obj is [String: Any])
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("\n\n"))
}

@Test func jsonCarriesTheContractFields() throws {
    let data = try verdict(.discard, reason: "improvement_below_min_effect",
                           warnings: ["w"], hits: [UnsafeHit(file: "A.swift", line: 2, construct: "unsafeBitCast")]).jsonData()
    let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(o["verdict"] as? String == "discard")
    #expect(o["reason"] as? String == "improvement_below_min_effect")
    #expect(o["build_configuration"] as? String == "release")
    #expect(o["stop_requested"] as? Bool == false)
    #expect((o["warnings"] as? [Any])?.count == 1)
    #expect((o["unsafe"] as? [Any])?.count == 1)
    #expect(o["score"] as? Double == 0.75)
}

@Test func humanReportStatesTheBuildConfiguration() {
    // Never leave ambiguity about which configuration produced the numbers.
    #expect(verdict(.keep).humanReport().contains("release"))
}

@Test func humanReportCallsOutCorrectedButNotSignificant() {
    let v = Verdict(kind: .discard, score: 0.98,
                    deltas: [BenchmarkDelta(benchmark: "A", baselineMedian: 100, candidateMedian: 98,
                                            ratio: 0.98, pValue: 0.03,
                                            significantAtAlpha: true, significantAtCorrected: false)],
                    reason: "no_significant_improvement", warnings: [], unsafeHits: [],
                    buildConfiguration: "release", stopRequested: false)
    let text = v.humanReport()
    #expect(text.contains("did not clear"), "must not silently relabel it 'not significant'")
}

@Test func resultsTSVAppendsWithAHeaderExactlyOnce() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("results.tsv")
    let row = ResultsRow(experiment: 1, commit: "abc1234", status: "keep", score: 0.75,
                         reason: "", unsafeCount: 0, toolVersion: "0.1.0", timestamp: "2026-09-16T00:00:00Z")
    try ResultsTSV.append(row, to: url)
    try ResultsTSV.append(row, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: ResultsTSV.header).count - 1 == 1)
    #expect(try ResultsTSV.read(url).count == 2)
    try FileManager.default.removeItem(at: dir)
}

// --- Additions beyond the brief, below this line. Proves the conclusions in
// the task-14 report: NaN/Infinity encoding, TSV injection, header
// idempotence on an empty file, and reader/writer consistency. ---

/// Removes `urls` when `body` returns OR throws, via `defer`. Same pattern
/// as `withTempDirectories` in GitTests.swift (private there, so duplicated
/// here rather than shared) - every fixture in this file must clean up on
/// the failure path too.
private func withTempDirectories<T>(_ urls: URL..., body: () throws -> T) rethrows -> T {
    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
    return try body()
}

private func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func jsonEncodesNaNScoreAsAStringNeverThrowsNeverZero() throws {
    // The "no_measurements" verdict reports score as .nan (Scoring.decide's
    // documented behavior) - this is exactly the run where a throwing
    // encoder would silently break the agent's loop, and where substituting
    // 0.0 would be indistinguishable from a genuine zero-ratio measurement.
    let v = Verdict(kind: .discard, score: .nan, deltas: [], reason: "no_measurements",
                    warnings: [], unsafeHits: [], buildConfiguration: "release", stopRequested: false)
    let data = try v.jsonData()
    let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(o["score"] as? String == "NaN")
    #expect(o["score"] as? Double == nil, "must not silently coerce to a numeric 0")
}

@Test func jsonEncodesInfiniteRatioAsAStringWithoutThrowing() throws {
    // baselineMedian == 0 makes ratio = candidateMedian / 0 = +inf.
    let v = Verdict(kind: .discard, score: 1.0,
                    deltas: [BenchmarkDelta(benchmark: "A", baselineMedian: 0, candidateMedian: 5,
                                            ratio: .infinity, pValue: 1.0,
                                            significantAtAlpha: false, significantAtCorrected: false)],
                    reason: "no_significant_improvement", warnings: [], unsafeHits: [],
                    buildConfiguration: "release", stopRequested: false)
    let data = try v.jsonData()
    let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let benchmarks = o["benchmarks"] as! [[String: Any]]
    #expect(benchmarks[0]["ratio"] as? String == "Infinity")
}

@Test func jsonDataWithConfigEmitsCorrectedAlphaDerivedFromTheVerdictNotTheDeclaredCount() throws {
    // config declares 4 benchmarks; this verdict only measured 2. The
    // corrected alpha reported must divide by the MEASURED count (2), not
    // the declared one (4) - Scoring.keepAlpha(config:) would wrongly
    // divide by 4 here and advertise a stricter bar than decide applied.
    let config = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench",
                        benchmarks: ["A", "B", "C", "D"], count: 10, alpha: 0.05,
                        minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
    let v = Verdict(kind: .keep, score: 0.8,
                    deltas: [
                        BenchmarkDelta(benchmark: "A", baselineMedian: 100, candidateMedian: 80,
                                      ratio: 0.8, pValue: 0.001, significantAtAlpha: true, significantAtCorrected: true),
                        BenchmarkDelta(benchmark: "B", baselineMedian: 100, candidateMedian: 99,
                                      ratio: 0.99, pValue: 0.9, significantAtAlpha: false, significantAtCorrected: false),
                    ],
                    reason: nil, warnings: [], unsafeHits: [], buildConfiguration: "release", stopRequested: false)
    let data = try v.jsonData(config: config)
    let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(o["k"] as? Int == 2)
    #expect(o["alpha"] as? Double == 0.05)
    #expect(o["corrected_alpha"] as? Double == 0.025) // 0.05 / 2, not 0.05 / 4
}

@Test func jsonDataWithoutConfigOmitsAlphaFieldsRatherThanGuessing() throws {
    let data = try verdict(.keep).jsonData()
    let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(o["alpha"] == nil)
    #expect(o["corrected_alpha"] == nil)
    #expect(o["k"] as? Int == 1)
}

@Test func addingPartialMeasurementWarningFiresOnlyWhenCountsDiffer() throws {
    let config = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench",
                        benchmarks: ["A", "B", "C"], count: 10, alpha: 0.05,
                        minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
    let partial = verdict(.keep).addingPartialMeasurementWarning(config: config)
    #expect(partial.warnings.contains { $0.contains("partial measurement") && $0.contains("1 of 3") })

    let matchingConfig = Config(version: 1, scope: ["Sources/**"], benchmarkTarget: "Bench",
                                benchmarks: ["A"], count: 10, alpha: 0.05,
                                minEffectPct: 1.0, maxRegressPct: 5.0, timeoutSeconds: 600)
    let full = verdict(.keep).addingPartialMeasurementWarning(config: matchingConfig)
    #expect(full.warnings.isEmpty)
}

@Test func resultsTSVRoundTripsFieldsContainingTabsAndNewlines() throws {
    // The agent controls things like branch/file-path-derived text that can
    // end up in `reason`; a tab would shift columns, a newline would forge
    // a fake extra row. Escaping must make the round trip lossless.
    let dir = try tempDir()
    try withTempDirectories(dir) {
        let url = dir.appendingPathComponent("results.tsv")
        let malicious = ResultsRow(
            experiment: 2, commit: "def5678",
            status: "discard",
            score: 0.5,
            reason: "line1\tline2\nFAKE\treason\trow\r\nend",
            unsafeCount: 1, toolVersion: "0.1.0", timestamp: "2026-09-16T01:00:00Z"
        )
        try ResultsTSV.append(malicious, to: url)
        let rows = try ResultsTSV.read(url)
        #expect(rows.count == 1, "a newline inside a field must not be read back as a second row")
        #expect(rows[0].reason == malicious.reason)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2, "header + exactly one physical line for the row")
    }
}

@Test func resultsTSVHeaderIsWrittenExactlyOnceEvenWhenTheFileExistsButIsEmpty() throws {
    let dir = try tempDir()
    try withTempDirectories(dir) {
        let url = dir.appendingPathComponent("results.tsv")
        // Simulate a pre-created-but-never-written (or truncated) file: it
        // EXISTS but has zero bytes, unlike the brief's fresh-UUID-dir case
        // which never creates the file at all.
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let row = ResultsRow(experiment: 1, commit: "abc1234", status: "keep", score: 0.75,
                             reason: "", unsafeCount: 0, toolVersion: "0.1.0", timestamp: "2026-09-16T00:00:00Z")
        try ResultsTSV.append(row, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(ResultsTSV.header), "an existing-but-empty file must still get the header")
        #expect(text.components(separatedBy: ResultsTSV.header).count - 1 == 1)
        #expect(try ResultsTSV.read(url).count == 1)
    }
}
