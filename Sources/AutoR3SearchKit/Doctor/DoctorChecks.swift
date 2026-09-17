// Sources/AutoR3SearchKit/Doctor/DoctorChecks.swift
//
// `doctor` answers one question: can THIS machine, right now, measure
// reliably enough that a human should trust an unattended overnight run on
// it? It is INFORMATIONAL and ALWAYS EXITS 0 (`DoctorCommand` never throws) —
// its whole job is to be read before trusting numbers, not to block anything.
//
// SHAPE: every judgment below is a PURE FUNCTION over INJECTED FACTS. The
// thing that actually reads the machine (`pmset`, `sysctl`, `uptime`,
// `xcode-select`, `FileManager`'s volume capacity, `swift package describe`,
// `git status`, an actual `swift build`) lives only in `all(repo:)`'s probe
// helpers at the bottom of this file. A judging function never shells out
// and never touches the filesystem, which is what makes
// `warnsWhenXCTestIsMissing` and friends deterministic on any machine the
// TESTS happen to run on, including one where every fact below is the
// opposite of true.
//
// Two policy choices worth stating up front:
//
//   1. EVERY probe degrades to a reported "could not determine" instead of
//      throwing. `doctor` must never fail the command — not on a repo with
//      no Package.swift, not on a machine missing `pmset`, not when
//      `swift package describe` itself fails. `all(repo:)` therefore never
//      calls `try` without `?` or a `do`/`catch` that turns a failure into a
//      Finding. A `Level` has only `.ok`/`.warn` (no third "unknown" case,
//      per the fixed interface), so "could not determine" is reported as
//      `.warn` — the one thing it must never do is silently look identical
//      to "checked and fine".
//   2. DO NOT OVER-WARN. A doctor that prints ten scary lines on a healthy
//      machine trains people to stop reading it. `DoctorRunner` (the
//      executable-facing formatter, in `DoctorCommand.swift`) prints an
//      explicit all-clear when every Finding is `.ok`, and nothing else —
//      no reassuring boilerplate before each `.ok` line, just the fact.
import Foundation

/// The judgement of one check. Two levels, not three, deliberately — see the
/// file comment on how "could not determine" is represented.
public enum Level: Equatable, Sendable {
    case ok, warn
}

/// One line of doctor's report. `title` is a short, stable label a human can
/// scan; `detail` carries the actual explanation and, for a `.warn`, the fix.
public struct Finding: Equatable, Sendable {
    public let level: Level
    public let title: String
    public let detail: String

    public init(level: Level, title: String, detail: String) {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

public enum DoctorChecks {

    // =====================================================================
    // MARK: - Pure judgements (the five from the brief, verbatim signatures)
    // =====================================================================

    /// The headline check. Verified at spike time: Command Line Tools alone
    /// do NOT ship the real `XCTest.framework` — only the private
    /// `XCTestSupport.framework` sits under the CLT SDKs — so a repository
    /// with XCTest test targets fails to build with "unable to resolve
    /// module dependency: 'XCTest'". `eval`'s gate 6 runs the repository's
    /// OWN tests, so a CLT-only machine simply cannot gate such a repo, and
    /// the failure it would hit is obscure. swift-testing based test targets
    /// are unaffected either way, and on Linux `swift-corelibs-xctest` ships
    /// with the toolchain, so this check only ever fires on Darwin.
    public static func xctestAvailability(developerDir: String?, hasXCTestFramework: Bool) -> Finding {
        if hasXCTestFramework {
            return Finding(
                level: .ok,
                title: "XCTest availability",
                detail: "XCTest.framework is available (developer directory: \(developerDir ?? "unknown")). " +
                    "A repository with XCTest test targets can be built and gated normally here."
            )
        }
        let location = developerDir.map { "the active developer directory is \($0)" }
            ?? "no active developer directory could be determined (`xcode-select -p` failed)"
        return Finding(
            level: .warn,
            title: "XCTest availability",
            detail: """
                XCTest.framework was not found -- \(location). Xcode's Command Line Tools alone do \
                not ship the real XCTest.framework, only the private XCTestSupport.framework, so a \
                repository with XCTest test targets fails to build here with "unable to resolve \
                module dependency: 'XCTest'". `eval`'s gate 6 runs the repository's OWN tests, so a \
                repo with any XCTest target cannot be gated on this machine at all -- and that failure \
                is obscure unless you already know to look for it. swift-testing based test targets \
                are unaffected. Fix: install Xcode (not just the Command Line Tools) from the App \
                Store or developer.apple.com, then run \
                `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
                """
        )
    }

    /// macOS throttles CPU frequency under Low Power Mode, which inflates
    /// timing noise for the exact reason this harness cares about noise at
    /// all: a quiet machine's own run-to-run variance is already wide enough
    /// to manufacture a spurious regression (see `competingLoad` below for
    /// the measured evidence), and Low Power Mode makes that worse on purpose.
    public static func lowPowerMode(_ enabled: Bool) -> Finding {
        guard enabled else {
            return Finding(level: .ok, title: "Low Power Mode", detail: "Low Power Mode is off.")
        }
        return Finding(
            level: .warn,
            title: "Low Power Mode",
            detail: """
                Low Power Mode is ON. macOS throttles CPU frequency under Low Power Mode, which \
                inflates run-to-run timing noise and can manufacture a spurious regression on a \
                multi-hour unattended run. Turn it off before measuring: System Settings > Battery \
                (or Energy on a desktop), or `sudo pmset -a lowpowermode 0` from a script.
                """
        )
    }

    /// Most laptops throttle under battery power for the same reason as Low
    /// Power Mode -- and an overnight run is exactly long enough to run the
    /// battery down mid-run, ending the measurement outright.
    public static func power(onAC: Bool) -> Finding {
        guard !onAC else {
            return Finding(level: .ok, title: "Power source", detail: "Running on AC power.")
        }
        return Finding(
            level: .warn,
            title: "Power source",
            detail: """
                Running on battery power. Most laptops throttle CPU frequency on battery to conserve \
                charge, which inflates benchmark noise and can manufacture a spurious regression -- \
                and a multi-hour unattended run risks running the battery down before it finishes. \
                Plug in before starting one.
                """
        )
    }

    /// The harness keeps a SECOND full build directory for the pinned
    /// baseline worktree, alongside the repository's own `.build` -- so the
    /// effective disk budget for a run is roughly double one release build's
    /// footprint, not one. Running out mid-run fails in whatever way the
    /// filesystem happens to fail a partial write, which is a much worse
    /// diagnostic experience than `doctor` saying so up front.
    public static func diskSpace(freeBytes: Int64) -> Finding {
        let thresholdBytes: Int64 = 20_000_000_000 // 20 GB
        let freeGB = Double(freeBytes) / 1_000_000_000
        guard freeBytes < thresholdBytes else {
            return Finding(level: .ok, title: "Free disk space",
                            detail: String(format: "%.1f GB free.", freeGB))
        }
        return Finding(
            level: .warn,
            title: "Free disk space",
            detail: String(format: """
                Only %.1f GB free. Swift release build directories are large, and this harness keeps \
                a SECOND one for the pinned baseline worktree in addition to the repository's own \
                `.build` -- an unattended run can exhaust disk partway through and fail in whatever \
                way the filesystem happens to fail a partial write. Free up space (aim for at least \
                20 GB) before a long run.
                """, freeGB)
        )
    }

    /// One round is one `BenchmarkTool` process invocation per side
    /// (`MeasureSession` samples baseline then candidate, `config.count`
    /// times, per benchmark) -- so the total process-run count scales
    /// directly with `benchmarks.count * count * 2`, on top of one release
    /// build and one `swift test` per `eval` call, neither counted here.
    public static func expectedRunLength(config: Config, secondsPerRound: Double) -> Finding {
        let processRuns = config.benchmarks.count * config.count * 2
        let estimatedSeconds = Double(processRuns) * secondsPerRound
        return Finding(
            level: .ok,
            title: "Expected measurement length",
            detail: String(format: """
                %d benchmark(s) x %d round(s) x 2 sides = %d process runs for one `eval`. At a fixed, \
                ASSUMED %.2fs per round (a built-in estimate, not a measurement of this repository's \
                own benchmark) that is about %@ of measurement time alone -- on top of one release \
                build and one `swift test`, neither counted here. The real per-round time varies with \
                the benchmark; treat this as a rough order of magnitude, not a prediction. Multiply by \
                however many experiments the agent's loop plans to run overnight.
                """, config.benchmarks.count, config.count, processRuns, secondsPerRound,
                Self.humanDuration(estimatedSeconds))
        )
    }

    // =====================================================================
    // MARK: - Additional pure judgements (required scope beyond the brief)
    // =====================================================================

    /// Informational only -- core layout by itself is neither good nor bad,
    /// just a fact worth having on hand when interpreting noise elsewhere in
    /// this report. `nil` (sysctl unavailable, e.g. not Apple silicon or not
    /// Darwin at all) is reported rather than guessed at.
    public static func coreCounts(performance: Int?, efficiency: Int?) -> Finding {
        guard let performance, let efficiency else {
            return Finding(
                level: .warn,
                title: "CPU core counts",
                detail: "Could not determine performance/efficiency core counts " +
                    "(`sysctl hw.perflevel0.logicalcpu` / `hw.perflevel1.logicalcpu`) -- " +
                    "probably not Apple silicon, or sysctl is unavailable on this platform."
            )
        }
        return Finding(level: .ok, title: "CPU core counts",
                        detail: "\(performance) performance + \(efficiency) efficiency logical CPUs.")
    }

    /// Another process competing for cycles is drift by another name: it
    /// lands unevenly on whichever side of the interleaved baseline/candidate
    /// comparison happens to be running when it spikes. Warns once the
    /// 1-minute load average claims more than half the logical CPUs.
    public static func competingLoad(loadAverage1m: Double?, logicalCPUs: Int?) -> Finding {
        guard let loadAverage1m, let logicalCPUs, logicalCPUs > 0 else {
            return Finding(
                level: .warn,
                title: "Competing load",
                detail: "Could not determine system load (`uptime`) or the total logical CPU count -- " +
                    "cannot judge how much of the machine other processes are using. Check manually " +
                    "with `uptime` and `top` before a long run."
            )
        }
        let busyFraction = loadAverage1m / Double(logicalCPUs)
        guard busyFraction > 0.5 else {
            return Finding(level: .ok, title: "Competing load",
                            detail: String(format: "1-minute load average is %.2f against %d logical CPUs.",
                                            loadAverage1m, logicalCPUs))
        }
        return Finding(
            level: .warn,
            title: "Competing load",
            detail: String(format: """
                1-minute load average is %.2f against %d logical CPUs (%.0f%% of capacity already \
                claimed by other processes). Competing load lands unevenly across an interleaved \
                baseline/candidate comparison and inflates noise. Close other applications before an \
                unattended run.
                """, loadAverage1m, logicalCPUs, busyFraction * 100)
        )
    }

    /// `eval` now REFUSES a dirty working tree outright -- it builds and
    /// measures the WORKING TREE while the scope gate inspects committed
    /// diffs, so an uncommitted edit would be measured but never gated -- and
    /// `baseline` refuses one too. Telling a human here means they find out
    /// from `doctor`, not from a refused `eval` partway through a plan.
    /// `nil` covers "not a readable git repository at this path at all".
    public static func workingTree(clean: Bool?) -> Finding {
        guard let clean else {
            return Finding(
                level: .warn,
                title: "Working tree",
                detail: "Could not determine whether the working tree is clean -- this does not look " +
                    "like a readable git repository (or `git status` failed). `baseline` and `eval` " +
                    "both require one; run doctor again from inside the repository you intend to measure."
            )
        }
        guard clean else {
            return Finding(
                level: .warn,
                title: "Working tree",
                detail: """
                    The working tree has uncommitted changes. `eval` builds and measures the WORKING \
                    TREE while the scope gate inspects committed diffs, so an uncommitted edit would be \
                    measured but never gated -- so both `baseline` and `eval` refuse to run at all on a \
                    dirty tree. A common cause is an untracked Package.resolved, which `swift build` \
                    writes into the package root; COMMIT it -- see the dependency-pin check below for \
                    why ignoring it instead is the one thing you must not do -- then commit or stash \
                    whatever else is left.
                    """
            )
        }
        return Finding(level: .ok, title: "Working tree", detail: "Clean -- no uncommitted changes.")
    }

    /// The softest link in the whole chain (flagged in `eval`'s own review):
    /// gate 6 runs the repository's OWN tests, which `@testable import` the
    /// code under optimization -- so a test gated with `.enabled(if:)` /
    /// `.disabled(if:)`, an `XCTSkip`, or a custom `ConditionTrait` DEFINED in
    /// optimizable source (e.g. `extension Trait { static var skipWhenSlow:
    /// ConditionTrait { .enabled(if: someFlag) } }`, referenced from a frozen
    /// test as `@Test(.skipWhenSlow)` -- the literal marker then never
    /// appears in the test file at all) can be switched off from IN-SCOPE
    /// code the agent is free to edit, WITHOUT touching any frozen file.
    /// `Package.swift` is frozen and the test files are frozen and restored
    /// every experiment, but the CONDITION such a gate reads can live
    /// entirely in optimizable code -- which is why `strongHits` below is
    /// scanned across BOTH the frozen test directories and the package's
    /// non-test source directories, not just the tests.
    ///
    /// `environmentReadCount` is kept SEPARATE and deliberately WEAKER: a
    /// bare `ProcessInfo.processInfo.environment` read with no skip construct
    /// near it is ordinary (CI detection, feature flags) and true of most
    /// real repositories -- warning on it would be the fastest way to train
    /// people to stop reading this check, so it is reported as `.ok`
    /// (informational), never `.warn`.
    ///
    /// There is no clean fix for every case, so this surfaces what it finds
    /// for a human to look at rather than pretending to catch every case --
    /// it is a heuristic, not a guarantee: a plain substring match, not an
    /// AST walk, so it can both miss a disguised condition and flag an
    /// innocent comment or string containing the same text. Its own stated
    /// blind spot -- a plain `guard`/early-return whose condition lives in
    /// optimizable code -- is NOT detectable by any text scan and is named
    /// explicitly in every branch below, so a human who reads this output
    /// knows what it cannot see, rather than assuming it caught everything.
    public static func conditionalTestGating(strongHits: [String], environmentReadCount: Int) -> Finding {
        let blindSpot = """
            Known blind spot: a plain `guard ... else { return }` (or any other early return) at the \
            top of a test, whose condition lives in optimizable code, disables that test using none \
            of the constructs this check can see. No text scan can catch that -- review tests with \
            non-trivial early setup by hand.
            """

        guard !strongHits.isEmpty else {
            if environmentReadCount > 0 {
                return Finding(
                    level: .ok,
                    title: "Conditionally-gated tests",
                    detail: """
                        \(environmentReadCount) test file line(s) read `ProcessInfo.processInfo.environment` \
                        with no skip construct (`.enabled(if:`, `.disabled(if:`, `XCTSkip`, `ConditionTrait`) \
                        nearby. Ordinary -- CI detection and feature flags both do this -- so this is \
                        informational, not a warning. It is noted because reading the environment is also \
                        how a test CAN be gated.
                        \(blindSpot)
                        """
                )
            }
            return Finding(
                level: .ok,
                title: "Conditionally-gated tests",
                detail: """
                    No `.enabled(if:)`, `.disabled(if:)`, `XCTSkip`, or `ConditionTrait` usage found in \
                    the frozen test target directories or the package's non-test source.
                    \(blindSpot)
                    """
            )
        }
        let shown = strongHits.prefix(20).joined(separator: "\n    ")
        let more = strongHits.count > 20 ? "\n    ... and \(strongHits.count - 20) more" : ""
        return Finding(
            level: .warn,
            title: "Conditionally-gated tests",
            detail: """
                Found \(strongHits.count) place(s) that could disable a test conditionally -- inside a \
                frozen test target directory, OR a `ConditionTrait` / `.enabled(if:` / `.disabled(if:` \
                definition in the package's non-test source (optimizable code a frozen test can still \
                reference by name, e.g. a custom `Trait` extension):
                    \(shown)\(more)
                This is a HEURISTIC (a plain text match, not an AST walk), not a guarantee -- it can \
                both miss a disguised condition and flag an innocent comment. Review each hit before \
                trusting an unattended run: gate 6 runs the repository's OWN tests, which `@testable \
                import` the code under optimization, so a condition living in in-scope code can switch \
                a test off without ever touching a frozen file.
                \(blindSpot)
                """
        )
    }

    /// Whether `.autor3search/config.yaml` exists at all. Always `.ok` --
    /// running `doctor` before `init` is an expected, ordinary state, not a
    /// problem to warn about. `all(repo:)` uses this to decide whether the
    /// build and run-length checks (which both need `Config`) are meaningful
    /// to attempt.
    public static func packageConfiguration(configured: Bool) -> Finding {
        guard configured else {
            return Finding(
                level: .ok,
                title: "Configuration",
                detail: "No .autor3search/config.yaml yet -- run `autor3search-swift init` before " +
                    "`baseline`/`eval`. The benchmark-build and expected-run-length checks below are " +
                    "skipped until then."
            )
        }
        return Finding(level: .ok, title: "Configuration", detail: ".autor3search/config.yaml found.")
    }

    /// THE DEPENDENCY PIN. Reports, loudly, the state that used to brick every
    /// repository with external dependencies -- and the state `doctor`'s own
    /// advice used to create.
    ///
    /// `swift package describe` (all `init` used to run) exits 0 and writes no
    /// `Package.resolved`. `swift build -c release --product <X>` writes one
    /// into the package ROOT. So a repository with source-control dependencies
    /// and no tracked lockfile had `baseline` record the hash of ZERO BYTES --
    /// a well-formed 64-hex value indistinguishable from a real pin -- and the
    /// first `eval`'s own build then created the file. From then on,
    /// permanently: `manifest_change_rejected` if the agent commits it,
    /// `dirty_working_tree` if it does not, with no way out because
    /// `frozenCommit` never advances.
    ///
    /// The second-order hole is why this check exists at all rather than just
    /// a better `baseline` refusal: `doctor` used to advise "commit or
    /// .gitignore it". The `.gitignore` branch leaves `packageResolvedSHA256`
    /// pinning nothing FOREVER, silently un-pinning every dependency -- the
    /// tool's own remedy disabling the check gate 2 exists to enforce. That
    /// advice is gone, and its outcome is now an alarm.
    ///
    /// - Parameters:
    ///   - externalDependencies: identities of declared dependencies SwiftPM
    ///     would pin (everything whose describe `type` is not `fileSystem`).
    ///     ADVISORY: it reads DIRECT dependencies only, so it can under-report
    ///     -- a path dependency whose own manifest pulls a source-control one
    ///     produces a root lockfile while this list is empty (verified live).
    ///     `lockfileExists` is therefore also treated as evidence of a real
    ///     dependency set, so the transitive case is not missed.
    ///   - lockfileTracked: `nil` when the question could not be asked (not a
    ///     git repository), which is not the same as a confident "no".
    ///   - recordedPins: `tag -> packageResolvedSHA256` for every baseline
    ///     record found for this repository. A pin equal to the SHA-256 of
    ///     zero bytes is the fingerprint of a baseline taken under the broken
    ///     behaviour.
    public static func dependencyPin(
        externalDependencies: [String],
        lockfileExists: Bool,
        lockfileTracked: Bool?,
        lockfileGitIgnored: Bool,
        recordedPins: [String: String]
    ) -> Finding {
        let title = "Dependency pin (Package.resolved)"
        let brokenTags = recordedPins.filter { Lockfile.isEmptyDataPin($0.value) }.keys.sorted()
        var problems: [String] = []

        // An ignore rule over the lockfile is the alarm, whatever else looks
        // healthy: it is one `git rm --cached` away from un-pinning
        // everything, and it is what this tool used to recommend.
        if lockfileGitIgnored {
            problems.append("""
                Package.resolved is excluded by an ignore rule (check .gitignore). An ignored \
                lockfile cannot be pinned: it is absent from frozenCommit, every worktree \
                checkout resolves its own, and baseline's recorded hash describes a file no run \
                is guaranteed to see. Earlier versions of this very check advised doing exactly \
                this. That advice was wrong. Remove the Package.resolved line from .gitignore.
                """)
        }

        // ONE condition, keyed on TRACKEDNESS, covering what used to be two
        // that flipped between runs (see `all`'s comment): "declares
        // dependencies but has no Package.resolved" and "Package.resolved
        // exists but is untracked" are the SAME problem -- there is no tracked
        // lockfile -- and doctor's own `swift build` turns the first into the
        // second by creating the file. Reporting them as one stable finding is
        // what makes repeated `doctor` runs, and `--skip-build` versus a real
        // build, agree with each other.
        //
        // `lockfileExists` still counts as evidence of an external dependency
        // set, not just `externalDependencies`: the manifest list reads DIRECT
        // dependencies only, so a package whose path dependency pulls a
        // source-control one has an empty list and a real lockfile.
        let hasExternalDependencies = !externalDependencies.isEmpty || lockfileExists
        if hasExternalDependencies, lockfileTracked != true {
            let declared = externalDependencies.isEmpty
                ? "resolves external dependencies"
                : "declares external dependencies (\(externalDependencies.joined(separator: ", ")))"
            problems.append("""
                This package \(declared) and git is not tracking a Package.resolved, so no \
                dependency version is pinned. `swift package describe` never writes that file but \
                `swift build` does, into the package root -- so an untracked copy appears by \
                itself, the first eval creates one if nothing else has, and every experiment \
                after that fails permanently as manifest_change_rejected or dirty_working_tree. \
                baseline refuses this state outright. Fix, and it is the same fix whether or not \
                an untracked copy is sitting there right now: \
                `swift package resolve && git add Package.resolved && git commit -m "pin \
                dependencies"` -- or re-run `autor3search-swift init`, which now does exactly \
                that and tells you the commit it made.
                """)
        }

        if !brokenTags.isEmpty {
            problems.append("""
                Baseline record(s) \(brokenTags.joined(separator: ", ")) pin \
                packageResolvedSHA256 to the SHA-256 of ZERO BYTES -- the fingerprint of a \
                baseline taken before this defect was fixed. It looks like a real pin and pins \
                nothing, so gate 2 cannot notice a dependency change for that run. Nothing here \
                rewrites it: silently "correcting" a recorded pin would mask exactly the change \
                the pin exists to catch. Commit Package.resolved, then re-run \
                `autor3search-swift baseline` under a NEW tag and continue from there; the old \
                run's results were measured against an unpinned dependency set and should not be \
                mixed with the new one's.
                """)
        }

        guard problems.isEmpty else {
            return Finding(level: .warn, title: title, detail: problems.joined(separator: "\n\n"))
        }

        if lockfileExists {
            return Finding(level: .ok, title: title,
                            detail: "Package.resolved is present and tracked, so baseline pins a real " +
                                "dependency set.")
        }
        // No lockfile AND no declared external dependencies: the legitimate,
        // supported case. SwiftPM writes no Package.resolved for such a
        // package, not on `resolve` and not on `swift build -c release` (both
        // verified). Warning here would be a worse bug than the one this check
        // exists for, and the fastest way to teach people to skip this line.
        return Finding(level: .ok, title: title,
                        detail: "No external dependencies and no Package.resolved -- correct for this " +
                            "package; SwiftPM never creates one here.")
    }

    /// Judges the OUTCOME of an actual build attempt `all(repo:)` performs
    /// (`swift build -c release --product <benchmarkTarget>` and
    /// `--product BenchmarkTool`, BY NAME). A bare `swift build -c release`
    /// does NOT produce `BenchmarkTool` -- it is a dependency's executable
    /// product -- so this check exists specifically to catch that before an
    /// unattended `eval` hits `benchmark_build_failed` for the first time
    /// hours into a run.
    public static func measurementBuild(succeeded: Bool, detail: String) -> Finding {
        guard succeeded else {
            return Finding(
                level: .warn,
                title: "Benchmark build",
                detail: """
                    Building the measurement products failed: \(detail)
                    A bare `swift build -c release` does not produce `BenchmarkTool` -- it is a \
                    dependency's executable product and needs `--product BenchmarkTool` explicitly, \
                    which is what this check ran. `eval` will refuse the same way with \
                    `benchmark_build_failed`; fix the build before trusting an unattended run.
                    """
            )
        }
        return Finding(level: .ok, title: "Benchmark build",
                        detail: "`swift build -c release --product <benchmarkTarget>` and " +
                            "`--product BenchmarkTool` both succeeded.")
    }

    private static func humanDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%.1fm", minutes) }
        return String(format: "%.1fh", minutes / 60)
    }

    // =====================================================================
    // MARK: - Report formatting (pure, so it is testable without a machine)
    // =====================================================================

    /// Renders `findings` (in the order `all(repo:)` produced them) as the
    /// text `DoctorCommand` prints verbatim. Deliberately CALM on a healthy
    /// machine: every `.ok` line is one line, no reassuring boilerplate
    /// before it, and the summary at the end is the only place that says
    /// anything extra -- a single explicit all-clear when there is nothing
    /// to fix, so a human reading past ten `[OK]` lines still gets a clear
    /// verdict rather than having to count them.
    public static func report(findings: [Finding], repo: URL) -> String {
        var lines: [String] = []
        lines.append("autor3search-swift doctor")
        lines.append("  repository: \(repo.path)")
        lines.append("")
        for finding in findings {
            let tag = finding.level == .ok ? "[OK]  " : "[WARN]"
            lines.append("\(tag) \(finding.title)")
            for detailLine in finding.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("       \(detailLine)")
            }
            lines.append("")
        }
        let warnCount = findings.filter { $0.level == .warn }.count
        if warnCount == 0 {
            lines.append("All checks passed. This machine looks fit for an unattended run.")
        } else {
            lines.append("\(warnCount) check(s) need attention -- see WARN lines above before trusting an unattended run.")
        }
        return lines.joined(separator: "\n")
    }

    // =====================================================================
    // MARK: - `all(repo:)` -- the only place that reads the real machine
    // =====================================================================

    /// Runs every check against the real machine and `repo`, in report
    /// order, headline first. Never throws: every probe below degrades to a
    /// reported "could not determine" `Finding` instead, per the file
    /// comment's policy (1).
    ///
    /// - Parameter skipBuild: when true, skips the real `swift build -c
    ///   release --product <benchmarkTarget> / --product BenchmarkTool`
    ///   attempt (which writes `.build/` in `repo` and can take on the order
    ///   of 20-30s) and reports it as skipped instead. Default `false`
    ///   preserves the full check.
    /// - Parameter env: process environment, only so the state home (and with
    ///   it this repository's baseline records, which carry the dependency
    ///   pin) can be located the same way every other command locates it.
    ///   Trailing and defaulted, so every existing `all(repo:)` /
    ///   `all(repo:skipBuild:)` call site keeps working unchanged.
    public static func all(repo: URL, skipBuild: Bool = false,
                           env: [String: String] = ProcessInfo.processInfo.environment) -> [Finding] {
        var findings: [Finding] = []

        // --- XCTest availability (headline) ---
        let developerDir = probeDeveloperDir()
        findings.append(xctestAvailability(
            developerDir: developerDir,
            hasXCTestFramework: probeHasXCTestFramework(developerDir: developerDir)))

        // --- Low Power Mode / power source ---
        let power = probePower()
        findings.append(lowPowerMode(power.lowPowerModeOn))
        findings.append(Self.power(onAC: power.onAC))

        // --- CPU layout / competing load ---
        let performanceCores = probeSysctlInt("hw.perflevel0.logicalcpu")
        let efficiencyCores = probeSysctlInt("hw.perflevel1.logicalcpu")
        findings.append(coreCounts(performance: performanceCores, efficiency: efficiencyCores))

        let totalLogicalCPUs = probeSysctlInt("hw.logicalcpu")
            ?? { (p: Int?, e: Int?) -> Int? in
                guard let p, let e else { return nil }
                return p + e
            }(performanceCores, efficiencyCores)
        findings.append(competingLoad(loadAverage1m: probeLoadAverage1m(), logicalCPUs: totalLogicalCPUs))

        // --- Disk space ---
        if let freeBytes = probeFreeBytes(at: repo) {
            findings.append(diskSpace(freeBytes: freeBytes))
        } else {
            findings.append(Finding(level: .warn, title: "Free disk space",
                                     detail: "Could not determine free disk space at \(repo.path)."))
        }

        // --- Working tree cleanliness ---
        findings.append(workingTree(clean: try? Git(repo: repo).isClean()))

        // --- Conditionally-gated tests: needs `swift package describe` ---
        if let description = try? PackageDescribe.describe(repo: repo) {
            let testDirs = description.testTargets.map(\.path)
            let sourceDirs = description.targets.filter { $0.type != "test" }.map(\.path)
            let testScan = scanTestDirsForConditionalGating(repo: repo, testDirs: testDirs)
            let sourceHits = scanSourceDirsForConditionalGating(repo: repo, sourceDirs: sourceDirs)
            findings.append(conditionalTestGating(
                strongHits: testScan.strongHits + sourceHits,
                environmentReadCount: testScan.environmentReadCount))
        } else {
            findings.append(Finding(
                level: .warn,
                title: "Conditionally-gated tests",
                detail: "Could not run `swift package describe` in \(repo.path) -- is this a readable " +
                    "Swift package? Skipping the scan for conditionally-gated tests."))
        }

        // --- The dependency pin ---
        //
        // CORRECTED IN ROUND 2. This used to carry a comment claiming doctor
        // does not probe because "doctor is read-only ... resolve WRITES".
        // That was FALSE, and provably so: `probeMeasurementBuild` below runs
        // `swift build -c release`, which writes `Package.resolved` into the
        // package root. Observed live -- a second `doctor` run on the same
        // repository FLIPPED this finding from "declares external dependencies
        // and has no Package.resolved" to "exists but git is not tracking it",
        // because doctor itself had created the file it was warning about.
        //
        // Two consequences, both handled in `dependencyPin` rather than here:
        // the finding is keyed on TRACKEDNESS, which doctor's own build cannot
        // change, so it is identical on every run; and because it never depends
        // on whether an untracked copy happens to be on disk, `--skip-build`
        // (which writes nothing at all) and the normal path cannot disagree
        // about what they report.
        //
        // doctor still does not ADD a `swift package resolve` of its own. Not
        // because it would be the only write -- it would not -- but because
        // making the answer depend on a probe would reintroduce exactly the
        // `--skip-build`/normal-path divergence just closed.
        findings.append(dependencyPin(
            externalDependencies: (try? Lockfile.externalDependencyIdentities(repo: repo)) ?? [],
            lockfileExists: Lockfile.exists(in: repo),
            lockfileTracked: Lockfile.isTracked(repo: repo),
            lockfileGitIgnored: Lockfile.isGitIgnored(repo: repo) ?? false,
            recordedPins: recordedDependencyPins(repo: repo, env: env)))

        // --- Config-dependent checks: need .autor3search/config.yaml ---
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        guard let config = try? Config.load(configURL) else {
            findings.append(packageConfiguration(configured: false))
            return findings
        }
        findings.append(packageConfiguration(configured: true))
        findings.append(expectedRunLength(config: config, secondsPerRound: 1.0))

        if skipBuild {
            findings.append(Finding(
                level: .ok,
                title: "Benchmark build",
                detail: "Skipped (--skip-build). Run without that flag before trusting an unattended " +
                    "run -- `eval` still hard-fails with `benchmark_build_failed` on a broken build, " +
                    "and this check exists to catch that earlier, not to replace it."))
        } else {
            let buildOutcome = probeMeasurementBuild(repo: repo, config: config)
            findings.append(measurementBuild(succeeded: buildOutcome.succeeded, detail: buildOutcome.detail))
        }

        return findings
    }

    // =====================================================================
    // MARK: - Probes (the only impure code in this file)
    // =====================================================================

    private static let swiftBinary = URL(fileURLWithPath: "/usr/bin/swift")

    /// `tag -> packageResolvedSHA256` for every baseline record this
    /// repository has in the state home.
    ///
    /// Walks the state home's immediate children rather than asking for one
    /// tag, because `doctor` is not told which run the operator cares about --
    /// and a stale run carrying a pin of nothing is exactly what needs
    /// surfacing. Every failure degrades to "no records found": an unreadable
    /// or absent state home means doctor has nothing to say about recorded
    /// pins, not that doctor should fail.
    private static func recordedDependencyPins(repo: URL, env: [String: String]) -> [String: String] {
        guard let home = try? StateHome(repo: repo, env: env),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: home.root, includingPropertiesForKeys: nil)
        else { return [:] }

        var pins: [String: String] = [:]
        for entry in entries {
            let recordURL = entry.appendingPathComponent("baseline.json")
            guard FileManager.default.fileExists(atPath: recordURL.path),
                  let record = try? BaselineRecord.load(recordURL)
            else { continue }
            pins[record.tag] = record.packageResolvedSHA256
        }
        return pins
    }

    /// `xcode-select -p`, trimmed. `nil` if the command fails to launch or
    /// exits non-zero (no developer directory configured at all).
    private static func probeDeveloperDir() -> String? {
        guard let result = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"],
            cwd: URL(fileURLWithPath: "/"), timeout: 10),
            result.exitCode == 0
        else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Verified real path: Xcode's `XCTest.framework` lives at
    /// `<developer dir>/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework`.
    /// Command Line Tools alone never have this file -- only the private
    /// `.../SDKs/MacOSX*.sdk/System/Library/PrivateFrameworks/XCTestSupport.framework`,
    /// which is a different, unrelated framework.
    private static func probeHasXCTestFramework(developerDir: String?) -> Bool {
        guard let developerDir else { return false }
        let path = developerDir +
            "/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"
        return FileManager.default.fileExists(atPath: path)
    }

    /// `pmset -g` reports `lowpowermode 0`/`1`. `pmset -g batt` reports which
    /// source is currently in use as its first line; a desktop with no
    /// battery at all is treated as AC (never positively "on battery"),
    /// which is the correct default for the machine this was verified on
    /// (Apple silicon desktop, no `-InternalBattery-0` entry at all on some
    /// configurations).
    private static func probePower() -> (lowPowerModeOn: Bool, onAC: Bool) {
        let pmset = URL(fileURLWithPath: "/usr/bin/pmset")
        let root = URL(fileURLWithPath: "/")

        var lowPowerModeOn = false
        if let r = try? Subprocess.run(pmset, ["-g"], cwd: root, timeout: 10), r.exitCode == 0 {
            for line in r.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("lowpowermode") {
                    lowPowerModeOn = trimmed.hasSuffix("1")
                }
            }
        }

        var onAC = true
        if let r = try? Subprocess.run(pmset, ["-g", "batt"], cwd: root, timeout: 10), r.exitCode == 0 {
            onAC = !r.stdout.contains("Battery Power")
        }

        return (lowPowerModeOn, onAC)
    }

    /// `sysctl -n <name>`, parsed as an `Int`. `nil` on any failure --
    /// missing on non-Darwin, or the named sysctl not existing on this
    /// machine (e.g. an Intel Mac has no `hw.perflevel1.logicalcpu`).
    private static func probeSysctlInt(_ name: String) -> Int? {
        guard let r = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", name],
            cwd: URL(fileURLWithPath: "/"), timeout: 10),
            r.exitCode == 0
        else { return nil }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `uptime`'s 1-minute load average. macOS spells the line
    /// `load averages: 2.38 4.41 5.19`; Linux spells it
    /// `load average: 0.10, 0.05, 0.01`. Both are handled by taking the first
    /// token after whichever spelling matches, stripping a trailing comma.
    private static func probeLoadAverage1m() -> Double? {
        guard let r = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/uptime"), [],
            cwd: URL(fileURLWithPath: "/"), timeout: 10),
            r.exitCode == 0
        else { return nil }
        let output = r.stdout
        for marker in ["load averages:", "load average:"] {
            guard let range = output.range(of: marker) else { continue }
            let rest = output[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let firstToken = rest.split(separator: " ").first else { continue }
            let cleaned = firstToken.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            return Double(cleaned)
        }
        return nil
    }

    /// Free space at `path`'s volume via `URLResourceValues`, per the brief.
    /// Falls back to `FileManager.attributesOfFileSystem` if the resource
    /// value is unavailable (some volume types do not report the
    /// "important usage" key).
    ///
    /// `volumeAvailableCapacityForImportantUsage` is DARWIN-ONLY: neither
    /// `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` nor the
    /// matching `URLResourceValues` property exists in
    /// swift-corelibs-foundation, so the unguarded form is a COMPILE ERROR on
    /// Linux, not a runtime degradation. It is kept on Darwin rather than
    /// dropped for both platforms because it is the only API that accounts
    /// for purgeable space, so on macOS it reports what a build can actually
    /// use; `systemFreeSize` there over-reports. The `statfs`-backed
    /// `attributesOfFileSystem` fallback below is the portable path and is
    /// what Linux takes -- it is the SAME fallback Darwin already uses when
    /// the volume does not report the "important usage" key, so the Linux
    /// branch is a path this code exercised before Linux was in scope, not a
    /// new untested one.
    private static func probeFreeBytes(at path: URL) -> Int64? {
        #if canImport(Darwin)
        if let values = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        #endif
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// Strong markers: an actual skip/condition mechanism, scanned in BOTH
    /// the frozen test directories and the package's non-test source
    /// directories. `ConditionTrait` is swift-testing's actual type for a
    /// custom condition (`extension Trait { static var x: ConditionTrait {
    /// .enabled(if: ...) } }`) -- its name is specific enough that a plain
    /// substring match has low collision risk, unlike a generic word.
    private static let strongGatingMarkers = [".enabled(if:", ".disabled(if:", "XCTSkip", "ConditionTrait"]

    /// Weak marker: reading the environment is ordinary and, alone, not
    /// evidence of gating -- see `conditionalTestGating`'s doc comment on why
    /// this is reported separately and at `.ok`, not folded into
    /// `strongGatingMarkers`.
    private static let environmentMarker = "ProcessInfo.processInfo.environment"

    /// How many lines on either side of a strong-marker line still count as
    /// "nearby" when deciding whether an environment read is accounted for
    /// by a skip construct already flagged as a strong hit (so it is not
    /// ALSO double-counted as a bare, weak read). A fixed, small window --
    /// not a real dependency analysis, which a text scan cannot do.
    private static let nearbyLineWindow = 3

    /// Walks every `.swift` file under each declared TEST target directory.
    /// Every `strongGatingMarkers` hit is reported as `"path:line: <trimmed
    /// line>"`. Every `environmentMarker` line is counted toward
    /// `environmentReadCount` UNLESS a strong-marker line sits within
    /// `nearbyLineWindow` lines of it in the same file (then it is treated as
    /// already covered by that strong hit, not counted again separately).
    /// Matching itself runs against `file.matchLines` (comments and string
    /// literals blanked -- see `SwiftFile`), so a marker mentioned only in
    /// prose or a string cannot produce a hit; a marker inside a comment
    /// cannot disable a test, so filtering it out loses no real signal, only
    /// noise (this is the fix-round-2 response to the review's "cry wolf"
    /// finding: before it, this scan flagged its own doc comments). The
    /// DISPLAYED snippet still comes from `file.rawLines`, so a genuine hit
    /// still reads as real, unmangled source.
    private static func scanTestDirsForConditionalGating(
        repo: URL, testDirs: [String]
    ) -> (strongHits: [String], environmentReadCount: Int) {
        var strongHits: [String] = []
        var environmentReadCount = 0
        for dir in testDirs.sorted() {
            for file in swiftFiles(repo: repo, dir: dir) {
                var strongLineIndices: [Int] = []
                for (index, matchLine) in file.matchLines.enumerated() {
                    for marker in strongGatingMarkers where matchLine.contains(marker) {
                        let shown = file.rawLines[index].trimmingCharacters(in: .whitespaces)
                        strongHits.append("\(file.relativePath):\(index + 1): \(shown)")
                        strongLineIndices.append(index)
                        break
                    }
                }
                for (index, matchLine) in file.matchLines.enumerated() where matchLine.contains(environmentMarker) {
                    let coveredByAStrongHit = strongLineIndices.contains { abs($0 - index) <= nearbyLineWindow }
                    if !coveredByAStrongHit {
                        environmentReadCount += 1
                    }
                }
            }
        }
        return (strongHits, environmentReadCount)
    }

    /// Walks every `.swift` file under each declared NON-TEST target
    /// directory (library and executable targets -- optimizable code) for
    /// `strongGatingMarkers`. This is what catches a custom `ConditionTrait`
    /// defined in in-scope source and referenced by name from a frozen test,
    /// where the literal marker never appears in the test file at all.
    /// Matches against `file.matchLines` for the same reason as the test-dir
    /// scan above -- this is the directory most likely to carry doc comments
    /// ABOUT the markers this check itself looks for (as `DoctorChecks.swift`
    /// demonstrates), so skipping comment/string content here matters most.
    private static func scanSourceDirsForConditionalGating(repo: URL, sourceDirs: [String]) -> [String] {
        var hits: [String] = []
        for dir in sourceDirs.sorted() {
            for file in swiftFiles(repo: repo, dir: dir) {
                for (index, matchLine) in file.matchLines.enumerated() {
                    for marker in strongGatingMarkers where matchLine.contains(marker) {
                        let shown = file.rawLines[index].trimmingCharacters(in: .whitespaces)
                        hits.append("\(file.relativePath):\(index + 1): \(shown) [non-test source, not a frozen file]")
                        break
                    }
                }
            }
        }
        return hits
    }

    /// `rawLines` is exactly the file's own text, one entry per line, used
    /// only for what gets DISPLAYED to a human. `matchLines` is the same
    /// file's text with every comment and string-literal's contents blanked
    /// to spaces (via `UnsafeDetector.stripCommentsAndStrings`, reused
    /// as-is rather than re-implemented -- it already exists, is already
    /// tested against nested block comments, raw/multiline strings, and
    /// line-count preservation, and solves precisely this class of problem
    /// for a different check in this same module), used only for MATCHING.
    /// The two arrays are always the same length and index-aligned, because
    /// `stripCommentsAndStrings` preserves line structure by construction.
    private struct SwiftFile {
        let relativePath: String
        let rawLines: [String]
        let matchLines: [String]
    }

    /// Every `.swift` file under `repo/dir`, each pre-split into lines once
    /// (shared by both scans above rather than re-reading the same file
    /// twice when a target happens to be scanned from two call sites).
    private static func swiftFiles(repo: URL, dir: String) -> [SwiftFile] {
        let dirURL = repo.appendingPathComponent(dir)
        guard let enumerator = FileManager.default.enumerator(
            at: dirURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            fileURLs.append(fileURL)
        }
        return fileURLs.sorted(by: { $0.path < $1.path }).compactMap { fileURL in
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
            let relativePath = fileURL.path.hasPrefix(repo.path)
                ? String(fileURL.path.dropFirst(repo.path.count + 1))
                : fileURL.path
            let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let stripped = UnsafeDetector.stripCommentsAndStrings(text)
            let matchLines = stripped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // Defensive, not expected to ever trip: `stripCommentsAndStrings`
            // preserves line count by construction (bound by
            // `stripCommentsAndStringsPreservesLineCount` in
            // `UnsafeDetectorTests`). If it ever didn't, matching against a
            // misaligned array would be silently wrong, which is worse than
            // falling back to matching on the raw, unstripped lines for this
            // one file -- i.e. the pre-fix-round-2 behaviour, not a crash.
            guard matchLines.count == rawLines.count else {
                return SwiftFile(relativePath: relativePath, rawLines: rawLines, matchLines: rawLines)
            }
            return SwiftFile(relativePath: relativePath, rawLines: rawLines, matchLines: matchLines)
        }
    }

    /// Actually builds, BY NAME, the two executables `eval` needs before it
    /// can measure anything: the configured benchmark target and
    /// `BenchmarkTool` itself (a dependency's product, so a bare
    /// `swift build -c release` would leave it absent -- see
    /// `EvalRunner.buildMeasurementProducts`, which this reuses directly
    /// rather than re-implementing the same two-product build a second way).
    /// Runs in `repo` itself, not a copy: a doctor run for a repository is a
    /// statement about THAT repository's own `.build`, matching what `swift
    /// build` run by hand would do.
    ///
    /// Prints an announcement to STDERR the instant before this blocks on the
    /// real build (measured elsewhere in this task at 24-33s) -- every other
    /// check above completes in milliseconds, and without this a healthy
    /// machine's `doctor` run goes completely silent for half a minute right
    /// after those, which is indistinguishable from a hang. The message is
    /// written synchronously here, before `EvalRunner.buildMeasurementProducts`
    /// is called, so it always appears before the pause, never after it.
    private static func probeMeasurementBuild(repo: URL, config: Config) -> (succeeded: Bool, detail: String) {
        announceBuildStarting(repo: repo, benchmarkTarget: config.benchmarkTarget)
        do {
            let failure = try EvalRunner.buildMeasurementProducts(
                swift: swiftBinary, in: repo, benchmarkTarget: config.benchmarkTarget,
                timeout: TimeInterval(config.timeoutSeconds), reasonPrefix: "doctor_benchmark_build",
                where: "the repository under test")
            guard let failure else { return (true, "") }
            return (false, failure.detail)
        } catch {
            return (false, "\(error)")
        }
    }

    /// The exact text a human sees on STDERR before the ~20-30s build pause.
    /// Names the command, the cost, the filesystem side effect, and the way
    /// out (`--skip-build`), all up front -- so it reads as "this is doing
    /// something, on purpose" rather than a stall. Written directly with
    /// `FileHandle.standardError`, matching this project's existing
    /// convention (`BaselineRunner.warn`), not buffered behind the report
    /// `DoctorCommand` prints only after `all(repo:)` returns.
    private static func announceBuildStarting(repo: URL, benchmarkTarget: String) {
        FileHandle.standardError.write(Data("""
            doctor: building the benchmark target and BenchmarkTool for real \
            (swift build -c release --product \(benchmarkTarget) and --product BenchmarkTool) -- \
            this writes .build/ in \(repo.path) and can take on the order of 20-30s. \
            Pass --skip-build for an instant (but incomplete) report.

            """.utf8))
    }
}
