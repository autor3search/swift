// Sources/AutoR3SearchKit/Commands/EvalRunner.swift
//
// One experiment, nine gates, one verdict.
//
// THE BUG THIS FILE EXISTS TO PREVENT. `baseline` records two commits.
// `frozenCommit` NEVER advances: the frozen test and benchmark files, and the
// scope gate, always compare against it, so the success criteria never move.
// `measurementCommit` ADVANCES to the candidate's commit after every KEEP.
// Without that advance, once one real improvement is kept, every later
// experiment -- including a commit that only adds a comment -- is measured
// against the stale original and coasts to KEEP on the strength of that old
// win. That bug shipped publicly in a sibling port. The advance lives at the
// very bottom of `evaluate`, and `docs/run-log.md` carries the mutation
// evidence: with those lines commented out, a no-op after a win returns KEEP.
//
// The advance has TWO halves and both are load-bearing:
//
//   1. `record.measurementCommit = kept` moves the number the next eval's
//      worktree-integrity gate checks against.
//   2. `Worktree.repoint` moves the pinned worktree's checkout, and the
//      per-eval baseline-side build below rebuilds that checkout's binaries --
//      specifically `swift build -c release --product <benchmarkTarget>` and
//      `--product BenchmarkTool`, BY NAME. A bare `swift build -c release` is
//      not sufficient: it exits 0 while leaving a dependency's executable
//      product (`BenchmarkTool`) absent, so the binaries gate 8 launches would
//      not be refreshed, or in the candidate's case would not exist at all.
//      See `buildMeasurementProducts` for the measurement. Advancing only the
//      number would leave the worktree still producing the ORIGINAL commit's
//      binary -- the same stale-baseline bug one layer down, where
//      `baseline.json` looks correct and every measurement is still against
//      the run's starting point.
//
// STDOUT. Nothing in this file writes to stdout, ever. `--json` is the agent's
// only channel and must carry exactly one object; the executable target is the
// sole writer. Diagnostics this runner produces are carried back inside the
// `Verdict`'s `warnings`, so they surface in both `--json` and `humanReport()`
// without either needing a side channel.
import Foundation

/// A run that was stopped by a refusal from `FrozenSnapshot.restore`.
///
/// A restore refusal means a symlink or a hard link appeared where a frozen
/// file should be -- i.e. something tried to turn the unattended restore into
/// an arbitrary-file-overwrite primitive on the operator's machine. It is an
/// alarm, not a flake, so it is recorded durably rather than being left to
/// scroll past in a log: the marker makes every later eval on this run refuse
/// up front, until a human has looked and deleted the file.
///
/// That is what caps the attacker's budget. A refusal aborts the WHOLE
/// restore, and `eval` never retries it, so an attacker racing the TOCTOU
/// window between `lstat` and `write` gets roughly one attempt per run, with
/// a logged alarm on every loss. If `eval` retried -- even three times -- the
/// budget would become unbounded over an overnight loop and that mitigation
/// would collapse.
enum RunTaint {
    static func url(runDir: URL) -> URL { runDir.appendingPathComponent("run.tainted") }

    /// The recorded refusal, or nil when the run is clean.
    static func pending(runDir: URL) -> String? {
        guard let data = try? Data(contentsOf: url(runDir: runDir)), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Best-effort: failing to WRITE the marker must not turn a refusal that
    /// was already correctly detected and reported into a different, less
    /// informative failure. The refusal itself is returned to the caller
    /// either way.
    static func record(runDir: URL, detail: String) {
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? Data(detail.utf8).write(to: url(runDir: runDir), options: .atomic)
    }
}

extension Verdict {
    /// A copy carrying extra warnings. `Scoring.decide` (frozen, Task 13)
    /// knows nothing about worktrees, git blobs or warm-up samples, so
    /// diagnostics raised around it are folded in here rather than by
    /// widening its signature.
    func adding(warnings extra: [String]) -> Verdict {
        guard !extra.isEmpty else { return self }
        return Verdict(
            kind: kind, score: score, deltas: deltas, reason: reason,
            warnings: warnings + extra, unsafeHits: unsafeHits,
            buildConfiguration: buildConfiguration, stopRequested: stopRequested)
    }
}

public enum EvalRunner {
    public static let runBranchPrefix = "autor3search-swift/"

    /// Gate 2a. Compares `Package.swift` and `Package.resolved` AS THEY ARE ON
    /// DISK against the hashes `baseline` recorded, and returns the failure to
    /// answer with, or `nil` when both match.
    ///
    /// See the call site for the bypass this closes. Three deliberate details:
    ///
    /// - **A missing file is a MISMATCH, never a throw.** `sha256File` now
    ///   refuses to hash a file that is not there, which is right for
    ///   `baseline` (recording a pin) and wrong here: a manifest deleted
    ///   mid-run is an experiment to REJECT with a scored verdict, not a
    ///   harness crash that produces no `results.tsv` row at all. `try?`
    ///   converts the throw into `nil`, and `nil` never equals a recorded
    ///   64-hex hash, so deletion lands in the same branch as rewriting.
    ///
    /// - **`Lockfile.absentPin` is checked by EXISTENCE, not by hash.** When
    ///   `baseline` recorded that this package produces no lockfile, the
    ///   assertion to enforce is "there is still no lockfile" -- a
    ///   `Package.resolved` APPEARING is the change. That is not a hypothetical
    ///   either: an ignored lockfile (the state `doctor` used to recommend and
    ///   `init` now refuses) is invisible to `git status`, so gate 2b would see
    ///   a clean tree while `swift build` uses the file.
    ///
    /// - **Pure read.** No file is written and no subprocess is run, so this
    ///   keeps gate 1-4's "reject before anything is built or measured"
    ///   property (spec.md section 5) intact.
    static func manifestIntegrityFailure(repo: URL, record: BaselineRecord) -> GateFailure? {
        let bypassNote = """
            This is checked by HASH against the bytes on disk, not by which paths git reports as \
            changed: `git update-index --assume-unchanged` (or `--skip-worktree`) hides an edit \
            from both the scope gate and the dirty-tree gate, while `swift build` still reads the \
            edited file. Restore the file to what baseline recorded, or start a new run with a \
            new baseline if the change is intended.
            """

        let livePackageSwift = try? BaselineRunner.sha256File(
            repo.appendingPathComponent("Package.swift"))
        if livePackageSwift != record.packageSwiftSHA256 {
            return GateFailure(reason: "manifest_change_rejected", detail: """
                Package.swift on disk does not match what baseline recorded \
                (\(livePackageSwift.map { "sha256 \($0)" } ?? "the file is missing") vs \
                \(record.packageSwiftSHA256)). The manifest decides how the candidate is \
                COMPILED -- `-Ounchecked` alone turns off bounds checking, which wins a \
                measurement without anyone writing faster code -- so any change to it is \
                rejected outright.

                \(bypassNote)
                """)
        }

        if record.packageResolvedSHA256 == Lockfile.absentPin {
            guard !Lockfile.exists(in: repo) else {
                return GateFailure(reason: "manifest_change_rejected", detail: """
                    a \(Lockfile.name) exists on disk, but baseline recorded that this package \
                    produces none (it resolved no external dependencies). A lockfile appearing \
                    mid-run means the dependency set the candidate is built against is no longer \
                    the one that was pinned.

                    \(bypassNote)
                    """)
            }
            return nil
        }

        let liveLockfile = try? BaselineRunner.sha256File(Lockfile.url(in: repo))
        if liveLockfile != record.packageResolvedSHA256 {
            return GateFailure(reason: "manifest_change_rejected", detail: """
                \(Lockfile.name) on disk does not match what baseline recorded \
                (\(liveLockfile.map { "sha256 \($0)" } ?? "the file is missing") vs \
                \(record.packageResolvedSHA256)). That file pins every dependency version the \
                candidate is built against; gate 2 exists so the agent cannot win by changing a \
                dependency instead of the code.

                \(bypassNote)
                """)
        }
        return nil
    }

    /// Gate 2a, second half: EVERY manifest in the tree, not just the two at
    /// the root.
    ///
    /// The root-only check above closes the `--assume-unchanged` bypass for
    /// `Package.swift` and `Package.resolved` and leaves it wide open for
    /// `Sub/Package.swift`, `Package@swift-6.0.swift` and `.swiftpm/`.
    /// `ScopeGate.isManifestPath` does catch all three -- but BY PATH, and
    /// hiding a file from git's path accounting is precisely what the attack
    /// does. So `baseline` records the hash of every one of them and this
    /// compares the bytes on disk.
    ///
    /// Three failure shapes, all `manifest_change_rejected`:
    ///
    /// - **Changed or removed.** A recorded path whose bytes no longer hash to
    ///   what was recorded, a missing file included (`try?` -> `nil`, which
    ///   never equals a hash).
    /// - **APPEARED.** A manifest on disk that baseline did not record. A new
    ///   `Sub/Package.swift` is worth exactly as much to an attacker as an
    ///   edited one -- SwiftPM will honour it, and no recorded hash can
    ///   mismatch for a file that had no hash.
    /// - **No inventory at all.** A `BaselineRecord` written before this field
    ///   existed. That run is unprotected against every one of the above, so
    ///   it is refused rather than waved through on an empty inventory: "there
    ///   is no record" must not read as "there is nothing to check". The
    ///   operator re-runs `baseline` under a new tag, which is the same
    ///   migration answer this project gave for the empty-data dependency pin.
    static func manifestInventoryFailure(repo: URL, record: BaselineRecord) -> GateFailure? {
        guard let recorded = record.manifestSHA256 else {
            return GateFailure(reason: "baseline_predates_manifest_inventory", detail: """
                this baseline record has no manifest inventory, because it was written by a \
                version of autor3search-swift from before that existed. Without one, a manifest \
                anywhere but the repository root -- Sub/Package.swift, Package@swift-6.0.swift, \
                anything under .swiftpm/ -- can be rewritten behind git's back (`git update-index \
                --assume-unchanged`) and neither the scope gate nor the dirty-tree gate sees it, \
                while swift build compiles it. -Ounchecked alone wins a measurement with bounds \
                checking off.

                eval refuses rather than continue with no inventory: "this run has no record of \
                its manifests" must not be read as "this run has no manifests to check". Re-run \
                `autor3search-swift baseline` under a NEW tag to establish one. Results from this \
                run were measured without that protection and should not be mixed with the new \
                run's.
                """)
        }

        let live: [String: String]
        do {
            live = try BaselineRunner.manifestInventory(repo: repo)
        } catch {
            return GateFailure(reason: "manifest_change_rejected", detail: """
                could not inventory this repository's manifests to compare them against what \
                baseline recorded: \(error). Failing closed -- a check that cannot run is not a \
                check that passed.
                """)
        }

        // Sorted so the message is deterministic across runs; a rejection an
        // operator cannot diff against yesterday's is much harder to act on.
        let changed = recorded.keys.filter { live[$0] != recorded[$0] }.sorted()
        let appeared = live.keys.filter { recorded[$0] == nil }.sorted()
        guard !changed.isEmpty || !appeared.isEmpty else { return nil }

        var lines: [String] = []
        for path in changed {
            let liveHash = live[path].map { "sha256 \($0)" } ?? "the file is gone"
            lines.append("  changed:  \(path) (\(liveHash), baseline recorded \(recorded[path]!))")
        }
        for path in appeared {
            lines.append("  appeared: \(path) (baseline recorded no such file)")
        }

        return GateFailure(reason: "manifest_change_rejected", detail: """
            the package manifests on disk no longer match what baseline recorded:

            \(lines.joined(separator: "\n"))

            Every one of these decides how the candidate is COMPILED or which dependencies it is \
            compiled against. A manifest that APPEARED counts: SwiftPM honours a nested \
            Sub/Package.swift, substitutes Package@swift-<version>.swift for Package.swift when it \
            matches the toolchain, and reads .swiftpm/configuration/mirrors.json to decide where a \
            dependency comes from -- so adding one is as good as editing one.

            This is checked by HASH against the bytes on disk, not by which paths git reports as \
            changed, because `git update-index --assume-unchanged` (or `--skip-worktree`) hides an \
            edit from both the scope gate and the dirty-tree gate while swift build still reads \
            the edited file. Restore these files to what baseline recorded, or start a new run \
            with a new baseline if the change is intended.
            """)
    }

    /// Runs one experiment end to end and returns its verdict.
    ///
    /// Throws only on a genuine harness failure (the executable turns that
    /// into a CRASH verdict, exit 3). A failing child process -- a build that
    /// does not compile, a test that fails -- is DATA: it produces a FAIL
    /// verdict, exit 2, and a `results.tsv` row, never a throw.
    public static func run(
        repo: URL,
        env: [String: String],
        source: (any MetricSource)? = nil,
        now: () -> Date = Date.init
    ) throws -> Verdict {
        let git = Git(repo: repo)
        let home = try StateHome(repo: repo, env: env)
        let branch = try git.currentBranch()
        let tag = branch.hasPrefix(runBranchPrefix)
            ? String(branch.dropFirst(runBranchPrefix.count)) : branch
        let runDir = try home.runDir(tag: tag)
        let stopRequested = FileManager.default.fileExists(
            atPath: try home.stopRequestURL(tag: tag).path)

        // GATE 0: the run claim. `eval` is the only legitimate writer of this
        // run's state -- the baseline record, the pinned worktree, the frozen
        // files restored over the repository, and `results.tsv` -- so a
        // second concurrent eval REFUSES rather than queues. See
        // `RunClaim` for why the lock is an flock and not a lock file, and
        // for the two concrete corruptions (a doubled `results.tsv` header or
        // a torn row; a silently dropped baseline advance) it prevents.
        //
        // Taken BEFORE the baseline record is read, so the claim covers the
        // whole run including that read. The side effect is that an eval on a
        // repository with no baseline creates the run directory in order to
        // put a claim file in it -- the same directory `baseline` would have
        // created, holding one empty file.
        let claim: RunClaim
        do {
            claim = try RunClaim.acquire(at: try home.runClaimURL(tag: tag))
        } catch RunClaimError.alreadyHeld(let path, let holder) {
            return Verdict(
                kind: .fail, score: .nan, deltas: [],
                reason: "run_already_in_progress",
                warnings: ["\(RunClaimError.alreadyHeld(path: path, holder: holder))"],
                unsafeHits: [], buildConfiguration: "release", stopRequested: stopRequested)
        }
        // EVERY exit path, including a throw from anywhere below.
        defer { claim.release() }

        let timestamp = ISO8601DateFormatter().string(from: now())
        let resultsURL = repo.appendingPathComponent("results.tsv")

        var verdict: Verdict
        do {
            verdict = try evaluate(
                repo: repo, git: git, home: home, tag: tag, runDir: runDir,
                stopRequested: stopRequested, source: source)
        } catch {
            // A harness failure still earns a row. `results.tsv` is the
            // human's morning log of what an unattended agent did overnight,
            // and a night that ended in a crash is exactly the entry they
            // most need to find. The error is re-thrown afterwards so the
            // executable still exits 3.
            try? ResultsTSV.append(ResultsRow(
                experiment: nextExperimentNumber(at: resultsURL),
                commit: (try? git.head()) ?? "",
                status: VerdictKind.crash.rawValue, score: .nan,
                reason: "\(error)", unsafeCount: 0,
                toolVersion: BuildInfo.version, timestamp: timestamp), to: resultsURL)
            throw error
        }

        do {
            try ResultsTSV.append(ResultsRow(
                experiment: nextExperimentNumber(at: resultsURL),
                commit: (try? git.head()) ?? "",
                status: verdict.kind.rawValue,
                // NOT `score.isNaN ? 0 : score`. A zero in this column reads
                // as an infinitely good result; NaN reads as "there was no
                // score", which is the truth for a gate rejection. Task 14
                // rejected the same substitution in the JSON payload for the
                // same reason, and `%.4f` round-trips "nan" through
                // `ResultsTSV.read` unharmed.
                score: verdict.score,
                reason: verdict.reason ?? "",
                unsafeCount: verdict.unsafeHits.count,
                toolVersion: BuildInfo.version, timestamp: timestamp), to: resultsURL)
        } catch {
            verdict = verdict.adding(warnings: [
                "the verdict could not be appended to results.tsv (\(error)); the verdict itself stands"
            ])
        }

        return verdict
    }

    /// Gates 1 through 9, and the baseline advance.
    ///
    /// ORDERING. Gates 1 and 2 are pure reads: a scope violation or a
    /// loosened config is rejected before anything on disk has been touched.
    /// Gate 3 is the first gate that MUTATES the repository's working tree
    /// (it writes the frozen test and benchmark files back over whatever the
    /// agent did to them), so everything cheap and non-destructive is
    /// deliberately ahead of it.
    ///
    /// A later gate failing therefore leaves the working tree already
    /// restored. That is safe and intended: `restore` only ever writes frozen
    /// files back to their baseline contents, it is idempotent, and it only
    /// ever UNDOES an edit the agent was never allowed to make. What the
    /// agent sees afterwards is a working tree that may be dirty relative to
    /// its own HEAD, which its own `git reset --hard` on a non-KEEP verdict
    /// clears. `eval` deliberately does not roll the restore back on a later
    /// gate failure: rolling back would mean re-writing the agent's rejected
    /// edits to the frozen files, which is the one thing this harness must
    /// never do.
    private static func evaluate(
        repo: URL, git: Git, home: StateHome, tag: String, runDir: URL,
        stopRequested: Bool, source: (any MetricSource)?
    ) throws -> Verdict {
        // Every gate rejection goes through here, so all of them look the same
        // to the agent: kind `.fail` (exit 2), the machine-readable `reason` in
        // `--json`, and the human-readable `detail` as a warning above it.
        // `score` is `.nan`, never 0: nothing was measured, and a 0 in that
        // field reads as a perfect result.
        func fail(_ failure: GateFailure) -> Verdict {
            Verdict(kind: .fail, score: .nan, deltas: [], reason: failure.reason,
                    warnings: [failure.detail], unsafeHits: [],
                    buildConfiguration: "release", stopRequested: stopRequested)
        }

        // A run that has already refused a restore stays refused until a
        // human clears the marker. See `RunTaint`.
        if let taint = RunTaint.pending(runDir: runDir) {
            return fail(GateFailure(reason: "run_tainted", detail: """
                this run was stopped by a refused restore of its frozen files and has not been \
                cleared. \(taint) Nothing further will be measured on this run: a refusal means \
                a symlink or hard link appeared where a frozen file should be, which is an \
                alarm, not a transient error. Investigate the repository, then delete \
                \(RunTaint.url(runDir: runDir).path) to resume.
                """))
        }

        var record = try BaselineRecord.load(try home.baselineRecordURL(tag: tag))

        // ---- Gate 1: scope, including unconditional manifest rejection ----
        //
        // Compared against `frozenCommit`, never `measurementCommit`: moving
        // the measurement point must not move what counts as in-scope.
        let changed = try git.changedPaths(since: record.frozenCommit)
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        let config: Config
        do {
            config = try Config.load(configURL)
        } catch {
            // A config that cannot even be parsed is usually a config that
            // was edited, so answer with the authoritative statement first.
            let live = (try? BaselineRunner.sha256File(configURL)) ?? ""
            if live != record.configSHA256 {
                return fail(GateFailure(reason: "config_hash_mismatch", detail: """
                    .autor3search/config.yaml no longer matches what baseline recorded, and can \
                    no longer be read: \(error)
                    """))
            }
            return fail(GateFailure(reason: "config_unreadable", detail: "\(error)"))
        }
        // Note the ordering hazard, and why it is not a hole: this scope
        // check reads `scope` from the LIVE config, which has not been
        // integrity-checked yet. An agent that widens `scope` to sneak an
        // edit past this gate still hits gate 2 immediately below, which is
        // unconditional and compares against the hash baseline recorded. The
        // widened scope buys a rejection with a different reason, never a
        // pass. The spec fixes this gate order, so it is kept.
        do { try ScopeGate.check(changedPaths: changed, scope: config.scope) }
        catch let failure as GateFailure { return fail(failure) }

        // ---- Gate 2: config integrity ----
        let liveConfigHash = try BaselineRunner.sha256File(configURL)
        guard liveConfigHash == record.configSHA256 else {
            return fail(GateFailure(reason: "config_hash_mismatch", detail: """
                .autor3search/config.yaml changed since baseline. It is hashed at baseline \
                precisely so the rules cannot be loosened mid-run: alpha, min_effect_pct, \
                max_regress_pct, count and the benchmark list all decide what counts as a win, \
                and an agent that can edit them can win without making anything faster.
                """))
        }
        // ---- Gate 2a: manifest integrity, by HASH, not by path ----
        //
        // THE PATH GATES ARE NOT ENOUGH, and this is a live bypass, not a
        // theoretical one. Gate 1 asks git which PATHS changed between
        // `frozenCommit` and `HEAD`; gate 2b asks git whether the tree is
        // clean. Both answers come from git's index -- and an agent with a
        // shell owns the index:
        //
        //     git update-index --assume-unchanged Package.swift
        //     <rewrite Package.swift>            # e.g. add -Ounchecked
        //     <edit and commit an in-scope source file>
        //
        // `git status --porcelain` is then EMPTY (gate 2b sees a clean tree)
        // and `git diff --name-only frozenCommit HEAD` names only the source
        // file (gate 1 sees no manifest path) -- while `swift build`, which
        // reads the file ON DISK and not out of git, compiles the rewritten
        // manifest. `--skip-worktree` does the same thing. The prize is
        // exactly what this tool exists to prevent: `-Ounchecked` turns off
        // bounds checking, which wins the measurement without anyone writing
        // faster code. The same trick on `Package.resolved` swaps the
        // dependency set the benchmark is built against.
        //
        // So `packageSwiftSHA256` and `packageResolvedSHA256` -- recorded by
        // `baseline` since the beginning and, until now, READ BY NOTHING --
        // are compared here, against the bytes on disk. Hashes cannot be
        // talked out of noticing by the index.
        //
        // Placement: immediately after the config-integrity guard, so it is
        // still a pure read that runs before the restore (gate 3) writes a
        // byte, before gate 5 builds and long before gate 8 measures. The
        // reason string is the existing `manifest_change_rejected` vocabulary
        // -- spec.md's gate 1 already says any change to either manifest is
        // "rejected outright", and this is that same rule enforced through
        // the door the path check cannot see.
        if let failure = manifestIntegrityFailure(repo: repo, record: record) {
            return fail(failure)
        }
        // ...and the same check for every manifest that is not at the root:
        // nested packages, version-specific manifests, `.swiftpm/`. The root
        // pair keeps its own check above purely for the better diagnosis it
        // can give; this is what makes the spec's "regardless of scope" claim
        // true anywhere other than the repository root.
        if let failure = manifestInventoryFailure(repo: repo, record: record) {
            return fail(failure)
        }

        do { try config.validate() }
        catch {
            return fail(GateFailure(reason: "invalid_config", detail: """
                the config recorded at baseline does not validate: \(error)
                """))
        }

        // ---- Gate 2b: the working tree must be clean ----
        //
        // THE COASTING BUG THROUGH ANOTHER DOOR. Gate 1 diffs COMMITS
        // (`frozenCommit..HEAD`), but gates 5, 6 and 8 build and measure the
        // WORKING TREE. An uncommitted, out-of-scope edit -- a benchmark helper
        // target, a fixture-data file, anything outside the frozen manifest and
        // outside `scope` -- is therefore compiled into the candidate binary,
        // measured, and seen by no gate at all.
        //
        // The consequence is worse than one bad measurement. The pinned
        // worktree is a checkout of a COMMIT, so the edit exists only on the
        // candidate side and produces a fresh "win" on EVERY subsequent eval,
        // which `results.tsv` and `baseline.json` then attribute to commits
        // that do not contain it. That is exactly the failure this file exists
        // to prevent, reached by a route none of the other gates watch.
        // `baseline` already refuses a dirty tree for the analogous reason.
        //
        // PLACEMENT. The brief asked for this ahead of gate 1. It sits here
        // instead, between gate 2 and gate 3, for one concrete reason: the
        // frozen test `configEditIsRejectedByHashMismatch` edits
        // `.autor3search/config.yaml` WITHOUT committing it and requires the
        // answer `config_hash_mismatch`, which a dirty-tree check ahead of
        // gate 2 would pre-empt with a less informative refusal. Nothing is
        // lost: gates 1 and 2 are pure reads, so this still runs before the
        // first byte is written (gate 3) and long before the first byte is
        // built (gate 5) or measured (gate 8). Checking BEFORE the restore also
        // avoids a false positive -- restore deliberately rewrites frozen files
        // and would itself dirty the tree in a configuration whose `scope`
        // covers the frozen directories.
        if try !git.isClean() {
            let status = (try? git.run(["status", "--porcelain"])) ?? ""
            return fail(GateFailure(reason: "dirty_working_tree", detail: """
                the working tree has uncommitted changes, and eval refuses to measure one. The \
                scope gate inspects COMMITS (frozenCommit..HEAD) while the build, test and \
                measurement steps compile the WORKING TREE, so an uncommitted edit would be \
                measured but never gated -- and because the pinned baseline worktree is a \
                checkout of a commit, such an edit exists only on the candidate side and would \
                manufacture a fresh "win" on every later experiment, credited to commits that do \
                not contain it. Commit the change (so the scope gate can judge it) or discard it. \
                git status --porcelain:
                \(String(status.prefix(4000)))
                """))
        }

        // ---- Gates 3 and 4: restore frozen files, reject new ones ----
        //
        // The manifest is LOADED from what baseline persisted -- never
        // re-derived by re-running `swift package describe` and
        // re-snapshotting. Re-deriving would ask a different question ("what
        // is in the tree now?") that happens to give the same answer while
        // nothing has gone wrong, and would silently let an agent that
        // renamed or removed a test target slip out of the freeze. It would
        // also put a dependency-resolving network call in the middle of the
        // gate chain. For the same reason gate 4 uses `newFiles(repo:)` --
        // the form whose scope comes from what baseline actually froze --
        // rather than handing in a freshly computed directory list.
        let snapshot = try FrozenSnapshot.load(runDir.appendingPathComponent("frozen-manifest.json"))
        let frozenStore = try home.frozenDir(tag: tag)
        do {
            try snapshot.restore(repo: repo, from: frozenStore)
        } catch let error as FrozenError {
            // FATAL, NEVER RETRIED, RECORDED. See `RunTaint`.
            let detail = """
                refusing to continue: restoring the frozen test and benchmark files was refused. \
                \(error) Nothing was measured, and this iteration is NOT retried -- a refusal \
                means the tree stopped matching baseline in a way that only deliberate \
                tampering produces, and retrying would hand whoever is racing the restore an \
                unlimited number of attempts instead of one.
                """
            RunTaint.record(runDir: runDir, detail: detail)
            return fail(GateFailure(reason: "frozen_restore_refused", detail: detail))
        }

        let newFiles = try snapshot.newFiles(repo: repo)
        guard newFiles.isEmpty else {
            return fail(GateFailure(reason: "new_test_or_benchmark_file", detail: """
                files absent from the frozen manifest appeared in a frozen directory: \
                \(newFiles.joined(separator: ", ")). SwiftPM compiles a new file in an existing \
                test target with no Package.swift edit, so an unnoticed new file is a way to \
                add a passing test that shadows a frozen failing one.
                """))
        }

        // ---- Gates 5 and 6: release build, then tests ----
        //
        // A non-zero exit from either is DATA, not a harness failure: it
        // becomes a FAIL verdict with a machine-readable reason. Timeouts are
        // branched on `timedOut`, never on an exit code -- a signalled child
        // reports 128 + signal, so no specific code identifies a kill.
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        let timeout = TimeInterval(config.timeoutSeconds)

        let build = try Subprocess.run(swift, ["build", "-c", "release"], cwd: repo, timeout: timeout)
        if build.timedOut {
            return fail(GateFailure(reason: "build_timed_out", detail: """
                swift build -c release did not finish within timeout_seconds (\(config.timeoutSeconds)s) \
                and its process tree was killed.
                """))
        }
        guard build.exitCode == 0 else {
            return fail(GateFailure(reason: "build_failed",
                                    detail: String(build.stderr.suffix(4000))))
        }
        // A BARE `swift build` is NOT enough to put the two executables gate 8
        // launches on disk. Measured against a package that depends on
        // ordo-one/benchmark: after deleting both binaries, `swift build -c
        // release` exits 0 and leaves the benchmark target present but
        // `BenchmarkTool` ABSENT -- a bare build covers the root package's own
        // products and targets, and a dependency's executable product is not in
        // that set. `BenchmarkToolSource` then cannot launch
        // `<repo>/.build/release/BenchmarkTool` and gate 8 crashes on the first
        // real repository. Fail-closed (it can never produce a wrong KEEP) but
        // the tool would simply not work, so both products are built by name.
        if let failure = try buildMeasurementProducts(
            swift: swift, in: repo, benchmarkTarget: config.benchmarkTarget, timeout: timeout,
            reasonPrefix: "benchmark_build",
            where: "the candidate repository at \(repo.path)") {
            return fail(failure)
        }

        let tests = try Subprocess.run(swift, ["test"], cwd: repo, timeout: timeout)
        if tests.timedOut {
            return fail(GateFailure(reason: "tests_timed_out", detail: """
                swift test did not finish within timeout_seconds (\(config.timeoutSeconds)s) and \
                its process tree was killed. The frozen tests are the behaviour contract; a \
                candidate that makes them hang has not earned a measurement.
                """))
        }
        guard tests.exitCode == 0 else {
            return fail(GateFailure(reason: "tests_failed",
                                    detail: String(tests.stdout.suffix(4000))))
        }

        // ---- Gate 7: worktree integrity ----
        //
        // A single `Worktree.verify` is the complete gate: it checks HEAD
        // identity AND cleanliness (Task 7's ruling), so a worktree at the
        // right commit but locally modified fails closed here.
        let worktree = try home.worktreeURL(tag: tag)
        guard try Worktree.verify(at: worktree, expectedCommit: record.measurementCommit) else {
            return fail(GateFailure(reason: "worktree_integrity", detail: """
                the pinned measurement worktree at \(worktree.path) is not a clean checkout of \
                \(record.measurementCommit). Measuring against it would compare the candidate \
                with something other than the last accepted commit.
                """))
        }

        var warnings: [String] = []

        // The baseline SIDE must be built too, every eval. `Worktree.repoint`
        // moves the pinned checkout after each KEEP but leaves its `.build`
        // holding the PREVIOUS commit's binaries, and `BenchmarkToolSource`
        // measures whatever binary is at `<worktree>/.build/release/...`.
        // Without this, `measurementCommit` would advance on paper while
        // every measurement kept comparing against the run's original
        // binary -- the same bug this file exists to prevent, one layer down.
        // It runs AFTER gate 7 on purpose: the integrity check must see the
        // worktree as the previous eval left it, not as this eval's build
        // just rewrote it.
        let baselineBuild = try Subprocess.run(
            swift, ["build", "-c", "release"], cwd: worktree, timeout: timeout)
        if baselineBuild.timedOut {
            return fail(GateFailure(reason: "baseline_build_timed_out", detail: """
                building the pinned measurement worktree did not finish within \
                timeout_seconds (\(config.timeoutSeconds)s).
                """))
        }
        guard baselineBuild.exitCode == 0 else {
            return fail(GateFailure(reason: "baseline_build_failed", detail: """
                the pinned measurement worktree at \(worktree.path) (commit \
                \(record.measurementCommit)) no longer builds, so there is nothing to measure \
                the candidate against: \(String(baselineBuild.stderr.suffix(4000)))
                """))
        }
        // Same reason as on the candidate side, and mirroring
        // `BaselineRunner.warmBuild`: the bare build above does not produce a
        // dependency's executable product, so `BenchmarkTool` would be missing
        // from this worktree's `.build` too -- and after a KEEP re-points the
        // worktree, the benchmark target's binary there is the PREVIOUS commit's
        // until it is rebuilt by name.
        if let failure = try buildMeasurementProducts(
            swift: swift, in: worktree, benchmarkTarget: config.benchmarkTarget, timeout: timeout,
            reasonPrefix: "baseline_benchmark_build",
            where: "the pinned measurement worktree at \(worktree.path) (commit \(record.measurementCommit))") {
            return fail(failure)
        }
        // SwiftPM can leave files outside `.build` behind (a freshly written
        // `Package.resolved` for a package with a source-control dependency),
        // which would make the NEXT eval's gate 7 refuse. Repointing to the
        // same commit is a no-op checkout whose only job is to restore that
        // cleanliness; `clean -fd` leaves ignored build output, so the
        // binaries just built survive.
        if (try? Worktree.isClean(at: worktree)) != true {
            do { try Worktree.repoint(git: git, at: worktree, to: record.measurementCommit) }
            catch {
                warnings.append("""
                    the baseline-side build left the pinned worktree dirty and it could not be \
                    reset (\(error)); the next eval's worktree-integrity gate will refuse until \
                    this is cleared by hand.
                    """)
            }
        }

        // Unsafe annotation. Reported, never decisive: in Swift the unsafe
        // pointer APIs ARE the idiomatic way to write the optimizations this
        // tool exists to find, so a gate here would reject a large fraction
        // of genuine wins.
        let scan = unsafeDelta(git: git, repo: repo, frozenCommit: record.frozenCommit, changed: changed)
        warnings += scan.warnings

        // ---- Gate 8: measure, interleaved ----
        let metric: any MetricSource
        if let source {
            metric = source
        } else {
            metric = BenchmarkToolSource(
                benchmarkTarget: config.benchmarkTarget,
                storage: try home.benchStorageURL(tag: tag))
        }

        // WARM-UP, OUTSIDE THE COUNTED SESSION. `MeasureSession` samples
        // baseline first within every round, so any first-invocation cost --
        // page faults on a freshly written binary, a cold dyld cache, the
        // filesystem cache for the executable -- lands entirely on baseline,
        // inflating it, shrinking candidate/baseline, and biasing toward
        // KEEP: the dangerous direction. One discarded sample per benchmark
        // per side pays that cost before anything is counted. BOTH sides,
        // because the two binaries live in different worktrees and each pays
        // its own first-invocation cost. Roughly 10% overhead at count: 10.
        //
        // Deliberately here at the call site and NOT inside
        // `MeasureSession.run`: an extra `sample()` call in there would break
        // its frozen `alternatesSidesWithinOneSession` test, which is the
        // test that pins the interleaving this project's measurement
        // validity rests on.
        warnings += warmUp(benchmarks: config.benchmarks, baselineWorktree: worktree,
                           candidateWorktree: repo, source: metric, config: config)

        let samples = try MeasureSession.run(
            benchmarks: config.benchmarks, baselineWorktree: worktree,
            candidateWorktree: repo, source: metric, config: config)

        // ---- Gate 9: score ----
        var verdict = Scoring.decide(samples: samples, config: config,
                                     unsafeHits: scan.hits, stopRequested: stopRequested)
        verdict = verdict.addingPartialMeasurementWarning(config: config)
        verdict = verdict.adding(warnings: warnings)

        // ---- THE ADVANCE ----
        //
        // Three lines. Remove them and one real win lets every later no-op
        // coast to KEEP forever, because "baseline" silently stays at the
        // run's starting commit. `frozenCommit` is deliberately untouched:
        // moving the measurement point must never move the success criteria.
        if verdict.kind == .keep {
            let kept = try git.head()
            try Worktree.repoint(git: git, at: worktree, to: kept)
            record.measurementCommit = kept
            try record.save(to: try home.baselineRecordURL(tag: tag))
        }

        return verdict
    }

    // MARK: - Building what gate 8 actually launches

    /// Builds, BY NAME, the two executables `BenchmarkToolSource` invokes from
    /// `<directory>/.build/release/`: the configured benchmark target and
    /// `BenchmarkTool` itself.
    ///
    /// Measured, against a package depending on `ordo-one/benchmark`:
    ///
    /// ```
    /// $ rm .build/release/BenchmarkTool .build/release/Bench
    /// $ swift build -c release                        # exit 0
    ///   Bench present, BenchmarkTool ABSENT
    /// $ swift build -c release --product BenchmarkTool # exit 0
    ///   BenchmarkTool present
    /// ```
    ///
    /// `BenchmarkTool` is a product of the *dependency*, and a bare build
    /// builds the root package's own products and targets. Relying on the bare
    /// build alone leaves gate 8 with nothing to launch.
    ///
    /// Returns the gate failure to report, or nil when both products are on
    /// disk. `timedOut` is branched on before the exit code, for the same
    /// reason as everywhere else in this file: a signalled child reports
    /// `128 + signal`, so no specific code identifies a kill.
    static func buildMeasurementProducts(
        swift: URL, in directory: URL, benchmarkTarget: String, timeout: TimeInterval,
        reasonPrefix: String, where description: String
    ) throws -> GateFailure? {
        for product in [benchmarkTarget, "BenchmarkTool"] {
            let result = try Subprocess.run(
                swift, ["build", "-c", "release", "--product", product],
                cwd: directory, timeout: timeout)
            if result.timedOut {
                return GateFailure(reason: "\(reasonPrefix)_timed_out", detail: """
                    building product \(product) in \(description) did not finish within \
                    timeout_seconds (\(Int(timeout))s) and its process tree was killed.
                    """)
            }
            guard result.exitCode == 0 else {
                return GateFailure(reason: "\(reasonPrefix)_failed", detail: """
                    product \(product) could not be built in \(description), so there is nothing \
                    for the measurement step to launch. Gate 8 runs \
                    <...>/.build/release/BenchmarkTool against <...>/.build/release/\
                    \(benchmarkTarget), and a plain `swift build` does not produce a \
                    dependency's executable product. \(String(result.stderr.suffix(4000)))
                    """)
            }
        }
        return nil
    }

    // MARK: - Warm-up

    /// One DISCARDED sample per benchmark on each side. Failures are reported
    /// as warnings rather than thrown: the counted session immediately after
    /// runs the same code against the same binaries, so a real problem
    /// surfaces there with the error it deserves, and a warm-up hiccup does
    /// not get to fail a run on its own.
    static func warmUp(
        benchmarks: [String], baselineWorktree: URL, candidateWorktree: URL,
        source: any MetricSource, config: Config
    ) -> [String] {
        var warnings: [String] = []
        for benchmark in benchmarks {
            for (side, worktree) in [("baseline", baselineWorktree), ("candidate", candidateWorktree)] {
                do {
                    _ = try source.sample(benchmark: benchmark, in: worktree, config: config)
                } catch {
                    warnings.append("""
                        the discarded warm-up sample for "\(benchmark)" on the \(side) side failed \
                        (\(error)); the counted session ran anyway, so this side may carry its \
                        first-invocation cost.
                        """)
                }
            }
        }
        return warnings
    }

    // MARK: - Unsafe delta

    struct UnsafeScanResult {
        let hits: [UnsafeHit]
        let warnings: [String]
    }

    /// Newly-introduced unsafe constructs in the changed Swift files, plus
    /// any reason a file could not be scanned.
    ///
    /// STRICT DECODING. `Git.fileContents` returns raw `Data`, and
    /// `String(decoding:as:UTF8.self)` repairs invalid byte sequences to
    /// U+FFFD rather than failing. On a file that is not valid UTF-8 that
    /// silently changes what the lexical scanner sees -- possibly turning an
    /// `UnsafeMutablePointer` occurrence into something it no longer
    /// recognises -- and reports a clean scan of a file it never actually
    /// read. `String(data:encoding: .utf8)` is failable and strict, so a file
    /// that cannot be decoded becomes a named warning the human sees instead
    /// of an invisible under-report.
    ///
    /// The whole result is annotation, never a decision, so a scan failure
    /// degrades to a warning rather than failing the run.
    static func unsafeDelta(
        git: Git, repo: URL, frozenCommit: String, changed: [String]
    ) -> UnsafeScanResult {
        var baseHits: [UnsafeHit] = []
        var candidateHits: [UnsafeHit] = []
        var warnings: [String] = []

        for path in changed where path.hasSuffix(".swift") {
            do {
                let data = try git.fileContents(path, at: frozenCommit)
                if let text = String(data: data, encoding: .utf8) {
                    baseHits += UnsafeDetector.scan(source: text, file: path)
                } else {
                    warnings.append("""
                        unsafe scan: \(path) at \(frozenCommit) is not valid UTF-8, so its \
                        pre-existing unsafe constructs could not be established. Any unsafe \
                        construct in the candidate's copy of this file will be reported as new.
                        """)
                }
            } catch GitError.truncated(let command) {
                warnings.append("""
                    unsafe scan: \(path) at \(frozenCommit) exceeded the blob capture cap \
                    (\(command)), so its pre-existing unsafe constructs could not be \
                    established.
                    """)
            } catch {
                // Any other git failure here means the path does not exist at
                // `frozenCommit` -- the ordinary case for a file this
                // experiment added. Nothing pre-existed, so nothing to warn
                // about; every hit in the candidate is genuinely new.
            }

            let candidateURL = repo.appendingPathComponent(path)
            if FrozenSnapshot.isSymlink(candidateURL) {
                warnings.append("""
                    unsafe scan: \(path) is a symbolic link in the working tree and was not \
                    followed, so it was not scanned for unsafe constructs.
                    """)
                continue
            }
            guard let data = try? Data(contentsOf: candidateURL) else {
                // Deleted by this experiment. Nothing to scan.
                continue
            }
            if let text = String(data: data, encoding: .utf8) {
                candidateHits += UnsafeDetector.scan(source: text, file: path)
            } else {
                warnings.append("""
                    unsafe scan: \(path) in the working tree is not valid UTF-8 and was not \
                    scanned, so any unsafe construct it introduces is NOT reported below.
                    """)
            }
        }

        return UnsafeScanResult(
            hits: UnsafeDetector.newHits(baseline: baseHits, candidate: candidateHits),
            warnings: warnings)
    }

    // MARK: - results.tsv numbering

    /// The next experiment number for `results.tsv`.
    ///
    /// Derived from the file's own contents, which is the only source there
    /// is -- nothing else counts experiments. `max(highest number, row
    /// count) + 1` rather than the obvious `count + 1`, so the number stays
    /// strictly increasing across the two ways the file gets damaged by
    /// hand: rows deleted from the middle (count drops, the highest number
    /// does not, so `count + 1` would REUSE a number already in the file)
    /// and rows edited into an unparseable shape (which `ResultsTSV.read`
    /// drops, so both figures under-report and the row count is the better
    /// of the two). A truncated-to-empty file restarts at 1 -- there is no
    /// way to recover a history that is gone, and the number is a reading
    /// aid, not an identifier: the commit SHA in each row is what actually
    /// identifies an experiment, and nothing in the metric reads this column.
    static func nextExperimentNumber(at url: URL) -> Int {
        guard let rows = try? ResultsTSV.read(url), !rows.isEmpty else { return 1 }
        return max(rows.map(\.experiment).max() ?? 0, rows.count) + 1
    }
}
