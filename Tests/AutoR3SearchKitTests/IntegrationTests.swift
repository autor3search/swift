// Tests/AutoR3SearchKitTests/IntegrationTests.swift
//
// THE LOOP, END TO END, AGAINST A REAL PACKAGE.
//
// Every other test in this suite proves one piece in isolation, with the
// measurement injected through `MetricSource`. These tests inject nothing
// that decides a verdict: they stage the real `Fixtures/DemoPackage` (a real
// SwiftPM package with a real `ordo-one/benchmark` dependency), run the real
// `init` / `baseline` / `eval`, build it for real in release, and measure it
// by launching the real `BenchmarkTool` against the real benchmark binary.
// The KEEP comes from code that is genuinely faster and the DISCARD from code
// that genuinely does nothing.
//
// They are SLOW (each stages a package, builds it cold in release and in
// debug, and runs a full interleaved measurement session) and SERIALIZED: two
// of them running concurrently would be two heavy builds and two benchmark
// sessions competing for the same cores, which is exactly the condition that
// turns a timing comparison into a coin flip.
import Testing
import Foundation
@testable import AutoR3SearchKit

@Suite(.serialized)
struct IntegrationTests {

    // MARK: - The win

    /// A genuine optimization is KEPT.
    ///
    /// The staged fixture's `countWords` builds each word with `word = word +
    /// String(...)`, allocating a fresh `String` per character;
    /// `applyOptimizedCountWords` replaces it with one reserved buffer and a
    /// single pass over the UTF-8 bytes, falling back to the exact general
    /// implementation the moment a non-ASCII byte appears. Nothing about the
    /// benchmark, the frozen tests or the config changes -- the code just gets
    /// faster, and the harness has to notice on its own.
    @Test(.timeLimit(.minutes(10)))
    func aRealOptimizationIsKept() throws {
        let repo = try stageDemoPackage()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        _ = try InitRunner.run(repo: repo, force: false)
        try commitAll(repo, "init")
        _ = try BaselineRunner.run(repo: repo, tag: "it", env: env)

        try applyOptimizedCountWords(repo)      // reserveCapacity + a single pass
        try commitAll(repo, "optimize countWords")
        let started = Date()
        let v = try EvalRunner.run(repo: repo, env: env, source: nil, now: Date.init)
        printIntegrationVerdict("aRealOptimizationIsKept", v, wall: Date().timeIntervalSince(started))

        #expect(v.kind == .keep, "a genuine optimization was not kept: \(v.reason ?? "")")
        #expect(v.score < 0.99)
    }

    // MARK: - The property the whole project rests on

    /// NO COASTING. After a real KEEP, a genuine no-op must DISCARD.
    ///
    /// This is the single most important behavioural claim autor3search-swift
    /// makes, and the one defect that shipped publicly in a sibling port: if
    /// `measurementCommit` does not advance on a KEEP, every later experiment
    /// is still measured against the run's ORIGINAL commit, so one real win
    /// lets a comment-only commit -- and every no-op after it -- coast to KEEP
    /// forever, each one credited with the first win's improvement.
    ///
    /// Both halves of the advance are exercised here, and neither can be
    /// faked: the recorded commit must move (or gate 7 would refuse the
    /// repointed worktree) AND the worktree's binaries must be rebuilt at the
    /// new commit (or the second eval would still be comparing against the
    /// slow original binary and would return KEEP again on the strength of the
    /// first win).
    @Test(.timeLimit(.minutes(15)))
    func aNoOpAfterARealKeepDoesNotCoastToKeep() throws {
        let repo = try stageDemoPackage()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        _ = try InitRunner.run(repo: repo, force: false)
        try commitAll(repo, "init")
        let record = try BaselineRunner.run(repo: repo, tag: "it", env: env)

        try applyOptimizedCountWords(repo)
        try commitAll(repo, "optimize countWords")
        let win = try EvalRunner.run(repo: repo, env: env, source: nil, now: Date.init)
        printIntegrationVerdict("noCoasting/win", win, wall: 0)
        #expect(win.kind == .keep, "the setup for the no-coasting check did not win: \(win.reason ?? "")")

        // The advance actually happened, and only to `measurementCommit`.
        let advanced = try BaselineRecord.load(try StateHome(repo: repo, env: env)
            .baselineRecordURL(tag: "it"))
        let keptCommit = try Git(repo: repo).head()
        #expect(advanced.measurementCommit == keptCommit)
        #expect(advanced.frozenCommit == record.frozenCommit,
                "frozenCommit moved; the success criteria are no longer fixed")

        // Now a genuine no-op, on top of the win.
        var src = try String(contentsOf: repo.appendingPathComponent("Sources/Demo/Demo.swift"),
                             encoding: .utf8)
        src += "\n// a comment, and nothing else\n"
        try src.write(to: repo.appendingPathComponent("Sources/Demo/Demo.swift"),
                      atomically: true, encoding: .utf8)
        try commitAll(repo, "comment only, after a win")

        let started = Date()
        let noOp = try EvalRunner.run(repo: repo, env: env, source: nil, now: Date.init)
        printIntegrationVerdict("noCoasting/noOp", noOp, wall: Date().timeIntervalSince(started))
        #expect(noOp.kind == .discard, """
            a no-op coasted to \(noOp.kind) after a real win -- the measurement baseline did not \
            advance. reason: \(noOp.reason ?? "none")
            """)

        // And the no-op must not have moved the measurement point either.
        let after = try BaselineRecord.load(try StateHome(repo: repo, env: env)
            .baselineRecordURL(tag: "it"))
        #expect(after.measurementCommit == keptCommit)
    }

    // MARK: - The cheats

    /// Breaking behaviour and then weakening the frozen test that would have
    /// caught it does not work.
    ///
    /// WHICH GATE ANSWERS, AND WHY IT IS NOT THE ONE THE BRIEF EXPECTED. The
    /// brief predicted `tests_failed`: gate 3 restores the frozen test over
    /// the agent's weakened copy, gate 6 then runs it against the gutted
    /// `countWords` and it fails. That is a real defence and it is unit-tested
    /// directly (`FrozenSnapshotTests`, `EvalRunnerTests`). It is not what
    /// answers here, because an EARLIER gate gets there first: `init` derives
    /// `scope` from the package's own targets and deliberately excludes test
    /// and benchmark targets, so `Tests/DemoTests/DemoTests.swift` is outside
    /// `["Sources/Demo/**"]` and gate 1 rejects the commit as `out_of_scope`
    /// before a single byte is built, restored or measured. Asserting
    /// `tests_failed` here would have been asserting a reason this
    /// configuration can never produce. What the test pins instead is the
    /// property that actually matters: the cheat does not succeed, and it is
    /// refused before the benchmark is sampled even once. Note the corollary --
    /// because gate 1 answers first, gate 3 never runs and the weakened test is
    /// still on disk afterwards. That is correct: the verdict is FAIL, and the
    /// agent's own `git reset --hard` on a non-KEEP is what clears it.
    @Test(.timeLimit(.minutes(10)))
    func weakeningAFrozenTestDoesNotHelp() throws {
        let repo = try stageDemoPackage()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        _ = try InitRunner.run(repo: repo, force: false)
        try commitAll(repo, "init")
        _ = try BaselineRunner.run(repo: repo, tag: "it", env: env)

        // Break behaviour, then weaken the test so it passes anyway.
        try "public func countWords(_ s: String) -> [String: Int] { [:] }"
            .write(to: repo.appendingPathComponent("Sources/Demo/Demo.swift"), atomically: true, encoding: .utf8)
        try "import Testing\n@Test func trivial() { #expect(true) }"
            .write(to: repo.appendingPathComponent("Tests/DemoTests/DemoTests.swift"), atomically: true, encoding: .utf8)
        try commitAll(repo, "cheat")

        let counter = GateSampleCounter()
        let v = try EvalRunner.run(repo: repo, env: env, source: counter, now: Date.init)
        printIntegrationVerdict("weakenedFrozenTest", v, wall: 0)
        #expect(v.kind == .fail, "the weakened test was not rejected; the cheat succeeded")
        #expect(v.reason == "out_of_scope")
        #expect(counter.calls == 0, "the benchmark was sampled despite a gate rejection")
    }

    /// Rewriting the benchmark so it measures a hundredth of the work is
    /// rejected -- and, as above, rejected by the scope gate before anything
    /// is built or measured. spec.md 2.4: benchmarks are an executableTarget,
    /// so they are frozen too, and `init` keeps them out of `scope`.
    @Test(.timeLimit(.minutes(10)))
    func rewritingTheBenchmarkToMeasureLessIsRejected() throws {
        let repo = try stageDemoPackage()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        _ = try InitRunner.run(repo: repo, force: false)
        try commitAll(repo, "init")
        _ = try BaselineRunner.run(repo: repo, tag: "it", env: env)

        let bench = repo.appendingPathComponent("Benchmarks/Bench/Bench.swift")
        var text = try String(contentsOf: bench, encoding: .utf8)
        text = text.replacingOccurrences(of: "count: 200", with: "count: 1")
        try text.write(to: bench, atomically: true, encoding: .utf8)
        try commitAll(repo, "shrink the benchmark")

        let counter = GateSampleCounter()
        let v = try EvalRunner.run(repo: repo, env: env, source: counter, now: Date.init)
        printIntegrationVerdict("shrunkBenchmark", v, wall: 0)
        #expect(v.kind != .keep, "an agent shrank the benchmark and won")
        #expect(v.reason == "out_of_scope")
        #expect(counter.calls == 0, "the benchmark was sampled despite a gate rejection")
    }

    /// Touching `Package.swift` is refused outright, regardless of scope, and
    /// before the metric is ever sampled. `Package.swift` is the build-flag
    /// surface: an agent that can edit it can "win" by turning off bounds
    /// checking rather than by writing faster code.
    @Test(.timeLimit(.minutes(10)))
    func editingPackageSwiftIsRejectedBeforeAnythingIsMeasured() throws {
        let repo = try stageDemoPackage()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        _ = try InitRunner.run(repo: repo, force: false)
        try commitAll(repo, "init")
        _ = try BaselineRunner.run(repo: repo, tag: "it", env: env)

        let manifest = repo.appendingPathComponent("Package.swift")
        var text = try String(contentsOf: manifest, encoding: .utf8)
        text = text.replacingOccurrences(
            of: #".target(name: "Demo")"#,
            with: #".target(name: "Demo", swiftSettings: [.unsafeFlags(["-Ounchecked"])])"#)
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        try commitAll(repo, "turn off bounds checking")

        let counter = GateSampleCounter()
        let v = try EvalRunner.run(repo: repo, env: env, source: counter, now: Date.init)
        printIntegrationVerdict("packageSwiftEdit", v, wall: 0)
        #expect(v.kind == .fail)
        #expect(v.reason == "manifest_change_rejected")
        #expect(counter.calls == 0, "the benchmark was sampled despite a gate rejection")
    }

    // MARK: - The no-op

    /// A comment-only commit is measured for real and DISCARDED. Nothing about
    /// this one is simulated: the candidate and the baseline are the same
    /// algorithm, compiled twice, measured interleaved, and the harness has to
    /// conclude "nothing moved" from the timings alone.
    @Test(.timeLimit(.minutes(10)))
    func aCommentOnlyCommitIsNotKept() throws {
        let repo = try stageDemoPackage()
        let env = isolatedStateEnv()
        defer { cleanUpFixture(repo: repo, env: env) }
        _ = try InitRunner.run(repo: repo, force: false)
        try commitAll(repo, "init")
        _ = try BaselineRunner.run(repo: repo, tag: "it", env: env)

        var src = try String(contentsOf: repo.appendingPathComponent("Sources/Demo/Demo.swift"), encoding: .utf8)
        src += "\n// a comment, and nothing else\n"
        try src.write(to: repo.appendingPathComponent("Sources/Demo/Demo.swift"), atomically: true, encoding: .utf8)
        try commitAll(repo, "comment only")

        let started = Date()
        let v = try EvalRunner.run(repo: repo, env: env, source: nil, now: Date.init)
        printIntegrationVerdict("aCommentOnlyCommitIsNotKept", v, wall: Date().timeIntervalSince(started))
        #expect(v.kind == .discard, "a comment was kept: \(v.reason ?? "none")")
    }
}

// MARK: - Fixture staging

/// Copies `Fixtures/DemoPackage` to a fresh temporary directory and makes it a
/// git repository with one commit.
///
/// The fixture is located from `#filePath` rather than from the process's
/// working directory: `swift test` does not guarantee what the working
/// directory is, and the package is deliberately NOT a test-target resource
/// (SwiftPM would flatten and process it, and a nested `Package.swift` inside
/// a resource bundle is not something to invite).
///
/// `.build` is skipped when copying. Nothing should ever build inside the
/// checked-in fixture, but if something did, copying a stale build directory
/// into every staged repository would silently make "cold build" measurements
/// mean something different.
func stageDemoPackage() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // AutoR3SearchKitTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // package root
        .appendingPathComponent("Fixtures/DemoPackage")
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Package.swift").path),
            "the DemoPackage fixture is missing at \(source.path)")

    let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    let fm = FileManager.default
    guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
        throw CocoaError(.fileReadUnknown)
    }
    for case let item as URL in walker {
        let relative = String(item.path.dropFirst(source.path.count + 1))
        if relative == ".build" || relative.hasPrefix(".build/") {
            walker.skipDescendants()
            continue
        }
        let target = dest.appendingPathComponent(relative)
        let isDirectory = (try item.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
        if isDirectory {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: item, to: target)
        }
    }

    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        git init -q -b main . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m "the package under test"
        """], cwd: dest, env: nil, timeout: 120)
    #expect(r.exitCode == 0, "staging the demo package failed: \(r.stderr)")
    return dest
}

/// Commits everything currently in the working tree, and asserts that the tree
/// is clean afterwards.
///
/// The cleanliness check is not decoration: `eval` refuses a dirty working
/// tree outright (`dirty_working_tree`) and rejects a committed
/// `Package.resolved` as a manifest change, so a helper that silently left an
/// untracked file behind would turn every test below into a test of one of
/// those refusals instead of the thing it means to check.
///
/// `Package.resolved` is the live example, and finding it is why this check is
/// here. `swift package describe` (which is all `init` runs) does NOT write it;
/// `swift build` does -- so on a package that does not track a lockfile, the
/// FIRST `eval` creates one, and from then on every experiment dies as either
/// `dirty_working_tree` or `manifest_change_rejected`. The fixture therefore
/// commits a `Package.resolved`, exactly as a real package with dependencies
/// does; see the Task 21 report and `docs/run-log.md`.
func commitAll(_ repo: URL, _ message: String) throws {
    let add = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                                 ["-c", "git add -A && git commit -q -m \"\(message)\""],
                                 cwd: repo, env: nil, timeout: 120)
    #expect(add.exitCode == 0, "commit \"\(message)\" failed: \(add.stderr)\(add.stdout)")
    let status = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                                    ["-c", "git status --porcelain"],
                                    cwd: repo, env: nil, timeout: 120)
    #expect(status.stdout.isEmpty,
            "the tree is still dirty after committing \"\(message)\": \(status.stdout)")
}

/// The optimization the KEEP case is built on.
///
/// One reserved byte buffer and a single pass over the string's UTF-8, in
/// place of a fresh `String` allocation per character. It is a real
/// optimization, not a shortcut: the byte-wise path handles ASCII only and
/// hands the WHOLE string to the exact general implementation the moment a
/// non-ASCII byte appears, so case folding and grapheme boundaries outside
/// ASCII keep their original meaning. Verified equivalent to the original over
/// 200,000 random strings drawn from an alphabet including `é`, `Ü`, `ß`, `漢`
/// and a combining acute accent: zero mismatches (see the Task 21 report).
func applyOptimizedCountWords(_ repo: URL) throws {
    try """
    public func countWords(_ s: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(64)
        var word: [UInt8] = []
        word.reserveCapacity(32)

        for byte in s.utf8 {
            switch byte {
            case 0x61...0x7A, 0x30...0x39:          // a-z, 0-9
                word.append(byte)
            case 0x41...0x5A:                        // A-Z
                word.append(byte + 0x20)
            case 0x20:                               // the field separator
                if !word.isEmpty {
                    counts[String(decoding: word, as: UTF8.self), default: 0] += 1
                    word.removeAll(keepingCapacity: true)
                }
            case 0x80...0xFF:
                // Non-ASCII: the byte-wise fast path cannot reproduce Unicode
                // case folding or grapheme boundaries, so the whole string goes
                // to the exact general implementation instead.
                return countWordsGeneral(s)
            default:
                break                                // punctuation: dropped, the word continues
            }
        }
        if !word.isEmpty { counts[String(decoding: word, as: UTF8.self), default: 0] += 1 }
        return counts
    }

    func countWordsGeneral(_ s: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for field in s.split(separator: " ") {
            var word = ""
            for ch in field where ch.isLetter || ch.isNumber {
                word.append(contentsOf: ch.lowercased())
            }
            if !word.isEmpty { counts[word, default: 0] += 1 }
        }
        return counts
    }

    """.write(to: repo.appendingPathComponent("Sources/Demo/Demo.swift"),
              atomically: true, encoding: .utf8)
}

/// A `MetricSource` that counts how many times it was asked for a sample.
///
/// Used by the gate tests to prove the REJECTION-BEFORE-MEASUREMENT property
/// directly rather than by inference: a gate that rejects a commit but has
/// already sampled the benchmark has spent the machine time it exists to save
/// and, worse, has run the agent's code. The value it returns is irrelevant --
/// in every test that injects it the expectation is that `calls` stays at
/// zero.
final class GateSampleCounter: MetricSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
        lock.lock(); count += 1; lock.unlock()
        return 1.0
    }
}

/// Prints the real numbers a verdict carries, so a test run's own output is
/// the evidence recorded in `docs/run-log.md`. Every figure published for this
/// task comes from these lines, not from a retyped summary.
func printIntegrationVerdict(_ label: String, _ v: Verdict, wall: TimeInterval) {
    var line = "[integration] \(label): verdict=\(v.kind.rawValue) score=\(v.score) " +
        "reason=\(v.reason ?? "none")"
    if wall > 0 { line += String(format: " wall=%.1fs", wall) }
    for d in v.deltas {
        line += "\n[integration]   \(d.benchmark): baselineMedian=\(d.baselineMedian)ns " +
            "candidateMedian=\(d.candidateMedian)ns ratio=\(d.ratio) p=\(d.pValue) " +
            "sigAtAlpha=\(d.significantAtAlpha) sigAtCorrected=\(d.significantAtCorrected)"
    }
    print(line)
}
