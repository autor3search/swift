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

    /// Gate 2c. Walks the disk and compares every file OUTSIDE `scope`
    /// against what `baseline` recorded, returning the failure to answer with
    /// or `nil` when the tree matches.
    ///
    /// THE ROOT CAUSE THIS EXISTS FOR. Gate 1 derives "what did this candidate
    /// change?" from `git diff --name-only`, and gate 2b derives "is anything
    /// uncommitted?" from `git status`. SwiftPM compiles THE DISK. The agent
    /// controls git's view of its own repository -- `git update-index
    /// --assume-unchanged`, `--skip-worktree`, `.gitignore`,
    /// `.git/info/exclude` -- so every path-accounting gate has a door in it.
    /// The existing manifest inventory closed that door for MANIFESTS. This is
    /// the general form: `scope` is finally enforced against the bytes on
    /// disk, which is the surface `swift build` actually reads.
    ///
    /// Three failure shapes, all `out_of_scope` -- the same reason string gate
    /// 1 already uses, because it is the same rule ("nothing outside `scope`
    /// may change"), merely enforced through the door git could not see:
    ///
    /// - **Changed.** A recorded path whose bytes no longer hash to what was
    ///   recorded.
    /// - **Missing.** A recorded path that is gone. Deleting an out-of-scope
    ///   file is as much a change as editing one -- deleting a benchmark
    ///   helper's fixture data changes what is measured.
    /// - **EXTRA.** A file outside `scope` that baseline did not record.
    ///   Nothing can mismatch a hash that was never taken, so an appearing
    ///   file is otherwise free. This is also the shape a case-variant
    ///   manifest arrives in.
    ///
    /// - **No inventory at all** is a refusal of its own
    ///   (`baseline_predates_tree_inventory`), for the reason the manifest
    ///   inventory already established: "there is no record" must not read as
    ///   "there is nothing to check".
    ///
    /// PURE READ. It hashes files and writes nothing, so gate 1-4's "reject
    /// before anything is built or measured" property is intact.
    static func treeInventoryFailure(
        repo: URL, record: BaselineRecord, scope: [String]
    ) -> GateFailure? {
        guard let recorded = record.treeSHA256 else {
            return GateFailure(reason: "baseline_predates_tree_inventory", detail: """
                this baseline record has no out-of-scope file inventory, because it was written \
                by a version of autor3search-swift from before that existed. Without one, any \
                file outside `scope` -- a benchmark helper target holding the workload size, a \
                fixture data file, a generated source file -- can be rewritten behind git's back \
                (`git update-index --assume-unchanged`, `--skip-worktree`, or an ignore rule) and \
                neither the scope gate nor the dirty-tree gate sees it, while swift build \
                compiles it. Setting a benchmark helper's repeat count from 1750 to 1 wins a \
                measurement outright.

                eval refuses rather than continue with no inventory: "this run has no record of \
                its out-of-scope files" must not be read as "this run has no out-of-scope files \
                to check". Re-run `autor3search-swift baseline` under a NEW tag to establish one. \
                Results from this run were measured without that protection and should not be \
                mixed with the new run's.
                """)
        }

        let live: [String: String]
        do {
            live = try BaselineRunner.treeInventory(repo: repo, scope: scope)
        } catch {
            return GateFailure(reason: "out_of_scope", detail: """
                could not inventory this repository's out-of-scope files to compare them against \
                what baseline recorded: \(error). Failing closed -- a check that cannot run is \
                not a check that passed.
                """)
        }

        // Sorted, so two evals a day apart produce diffable messages.
        let changed = recorded.keys.filter { live[$0] != nil && live[$0] != recorded[$0] }.sorted()
        let missing = recorded.keys.filter { live[$0] == nil }.sorted()
        let extra = live.keys.filter { recorded[$0] == nil }.sorted()
        guard !changed.isEmpty || !missing.isEmpty || !extra.isEmpty else { return nil }

        var lines: [String] = []
        for path in changed {
            lines.append("  changed: \(path) (now \(live[path]!), baseline recorded \(recorded[path]!))")
        }
        for path in missing {
            lines.append("  missing: \(path) (baseline recorded \(recorded[path]!))")
        }
        for path in extra {
            lines.append("  extra:   \(path) (baseline recorded no such file)")
        }

        return GateFailure(reason: "out_of_scope", detail: """
            files OUTSIDE the configured scope \(scope) no longer match what baseline recorded:

            \(lines.joined(separator: "\n"))

            This is the scope rule enforced against the BYTES ON DISK, not against the paths git \
            reports as changed. `git update-index --assume-unchanged`, `--skip-worktree`, a \
            .gitignore entry and .git/info/exclude all hide a file from the scope gate and from \
            the dirty-tree gate while swift build still compiles it -- an out-of-scope benchmark \
            helper edited that way wins a measurement without a line of in-scope code changing. \
            An EXTRA file counts for the same reason a new manifest does: no recorded hash can \
            mismatch for a file that had no hash.

            Restore these files to what baseline recorded, or start a new run with a new baseline \
            if the change is intended. If the change genuinely belongs to the experiment, widen \
            `scope` and re-baseline -- in-scope files are judged by the scope gate on their \
            merits, not by this one.
            """)
    }

    /// Gate 2b. The working tree must be clean, INCLUDING files that only an
    /// ignore rule is hiding.
    ///
    /// Returns the failure to answer with, or `nil` when nothing is
    /// uncommitted and every present-but-ignored file is exactly as `baseline`
    /// recorded it.
    ///
    /// WHAT `--ignored` ADDS, and it is not hypothetical. `git status
    /// --porcelain` omits ignored files, so:
    ///
    ///   - Committing `Sources/Demo/.gitignore` containing `*.gen.swift` is an
    ///     in-scope, non-manifest change that gate 1 passes. Planting
    ///     `Sources/Demo/Boost.gen.swift` afterwards leaves `git status
    ///     --porcelain` EMPTY. Gate 4's new-file scan only walks the FROZEN
    ///     directories, so it never looks there. `swift build` compiles it.
    ///   - `.git/info/exclude` does the same with no repository file at all, so
    ///     there is nothing for any path-based gate to inspect, review or
    ///     commit.
    ///
    /// Either way the pinned measurement worktree is a checkout of a COMMIT and
    /// never contains the file, so the planted source manufactures a win on
    /// EVERY subsequent eval, credited to commits that do not contain it -- and
    /// `git add -A` will not commit it and `git reset --hard` will not remove
    /// it, so it does not even wash out between experiments. In a repository
    /// that already ignores `*.generated.swift` or `Generated/`, no `.gitignore`
    /// commit is needed at all.
    ///
    /// RECORD, DO NOT REFUSE, for the ignored half. The first version of this
    /// gate refused ANY present-but-ignored path outside a four-entry
    /// allowlist, and that is correct about the attack and wrong about the
    /// world: `autor3search-swift`'s own repository ignores `docs/` and
    /// `.superpowers/` and has both on disk, so `eval` refused on the tool's
    /// own source tree -- as it would on most real repositories, which ignore
    /// `.DS_Store`, editor state, vendored directories or pre-existing
    /// generated sources that genuinely exist.
    ///
    /// An ignored file already present when the baseline was taken is part of
    /// the honest starting point: `frozenCommit` was taken with it there and
    /// it gives neither side an advantage. What the attack requires is one
    /// that APPEARS or CHANGES after the freeze. So `baseline` records the set
    /// (`BaselineRunner.ignoredInventory`) and this compares against it, and
    /// only a difference is a refusal. Both attacks above plant a file that
    /// did not exist at baseline, so both still refuse.
    ///
    /// REMOVAL counts: deleting an ignored file the baseline build compiled
    /// changes what is compiled as much as adding one does.
    ///
    /// The harness's own outputs (`.build/`, `results.tsv`, `run.log`,
    /// `.autor3search/profiles/`) are excluded from the inventory on both
    /// sides -- they change every eval by design. That list is a constant,
    /// deliberately NOT derived from `.gitignore`: that file lives in the
    /// repository, so reading the exemptions out of it would let the agent
    /// grant itself more.
    ///
    /// UNCOMMITTED IS STILL UNCONDITIONAL, and that half has no inventory and
    /// no allowlist. In-scope CONTENT is legitimately allowed to change; it is
    /// never allowed to be uncommitted, because the pinned worktree measures a
    /// commit and an uncommitted file exists on the candidate side only.
    static func dirtyTreeFailure(git: Git, repo: URL, record: BaselineRecord) -> GateFailure? {
        let entries: [Git.StatusEntry]
        do {
            entries = try git.status(includingIgnored: true)
        } catch {
            return GateFailure(reason: "dirty_working_tree", detail: """
                could not read the working tree's status (\(error)). Failing closed -- a check \
                that cannot run is not a check that passed.
                """)
        }

        // ---- Half 1: uncommitted. Unconditional, as it always was. ----
        let uncommitted = entries.filter { !$0.isIgnored }
        if !uncommitted.isEmpty {
            let lines = uncommitted.map { entry -> String in
                let origin = entry.originalPath.map { " (from \($0))" } ?? ""
                return "  \(entry.code) \(entry.path)\(origin)"
            }
            return GateFailure(reason: "dirty_working_tree", detail: """
                the working tree has uncommitted changes, and eval refuses to measure one. The \
                scope gate inspects COMMITS (frozenCommit..HEAD) while the build, test and \
                measurement steps compile the WORKING TREE, so an uncommitted edit would be \
                measured but never gated -- and because the pinned baseline worktree is a \
                checkout of a commit, such an edit exists only on the candidate side and would \
                manufacture a fresh "win" on every later experiment, credited to commits that do \
                not contain it. Commit the change (so the scope gate can judge it) or discard it. \
                git status --porcelain:
                \(String(lines.joined(separator: "\n").prefix(4000)))
                """)
        }

        // ---- Half 2: ignored files that moved since the freeze. ----
        guard let recorded = record.ignoredSHA256 else {
            // Written by the same `baseline` that writes `treeSHA256`, so this
            // can only be a record from before either existed. Same reason
            // string rather than a second contract addition saying the same
            // thing.
            return GateFailure(reason: "baseline_predates_tree_inventory", detail: """
                this baseline record has no inventory of the files an ignore rule hides from git, \
                because it was written by a version of autor3search-swift from before that \
                existed. Without one there is no way to tell a file that was ALREADY there at the \
                freeze -- part of the honest starting point -- from one PLANTED afterwards, which \
                the pinned measurement worktree can never contain and which would manufacture a \
                win on every later experiment, credited to commits that do not contain it.

                Re-run `autor3search-swift baseline` under a NEW tag to establish one. Results \
                from this run were measured without that protection and should not be mixed with \
                the new run's.
                """)
        }

        let live: [String: String]
        do {
            live = try BaselineRunner.ignoredInventory(repo: repo, git: git)
        } catch {
            return GateFailure(reason: "dirty_working_tree", detail: """
                could not inventory the files an ignore rule is hiding from git, to compare them \
                against what baseline recorded: \(error). Failing closed -- a check that cannot \
                run is not a check that passed.
                """)
        }

        // Sorted, so two evals a day apart produce diffable messages.
        let added = live.keys.filter { recorded[$0] == nil }.sorted()
        let changed = recorded.keys.filter { live[$0] != nil && live[$0] != recorded[$0] }.sorted()
        let removed = recorded.keys.filter { live[$0] == nil }.sorted()
        guard !added.isEmpty || !changed.isEmpty || !removed.isEmpty else { return nil }

        var lines: [String] = []
        for path in added { lines.append("  added:    \(path) (baseline recorded no such file)") }
        for path in changed {
            lines.append("  modified: \(path) (now \(live[path]!), baseline recorded \(recorded[path]!))")
        }
        for path in removed {
            lines.append("  removed:  \(path) (baseline recorded \(recorded[path]!))")
        }

        return GateFailure(reason: "dirty_working_tree", detail: """
            files that an ignore rule hides from `git status` have changed since baseline, and \
            eval refuses to measure that:

            \(String(lines.joined(separator: "\n").prefix(4000)))

            An ignored file that was ALREADY present when the baseline was taken is fine and is \
            not listed here -- it is part of the honest starting point. These are not: an ignored \
            file is invisible to `git status --porcelain`, is not removed by `git reset --hard` \
            and is not added by `git add -A`, so one that appeared after the freeze is present on \
            the candidate side of every measurement and present in NO commit at all. The pinned \
            measurement worktree is a checkout of a commit and can never contain it, so it would \
            manufacture a win on every later experiment, credited to commits that do not contain \
            it. A removal counts for the same reason: the baseline build compiled that file.

            The rule doing the hiding may live in any .gitignore, in .git/info/exclude (which is \
            not a repository file and cannot be reviewed), in a global excludes file, or in \
            core.excludesFile. Run `git status --ignored` to see what is present and \
            `git check-ignore -v <path>` to find the rule. Commit the file (so the scope gate can \
            judge it) or remove it. The harness's own outputs are never inventoried: \
            \(BaselineRunner.harnessOutputFiles.joined(separator: ", ")), \
            \(BaselineRunner.harnessOutputDirectories.map { $0 + "/" }.joined(separator: ", ")).
            """)
    }

    /// Gate 2d. The dependency sources SwiftPM is about to compile must be the
    /// ones `Package.resolved` pins.
    ///
    /// `.build/` is exempt from the out-of-scope inventory
    /// (`neverWalkedDirectories`), exempt from the dirty-tree gate
    /// (`isHarnessOutput`), and git collapses it to one `!!` record. That
    /// blanket exemption was the hole: `.build/checkouts` is not build output.
    /// It is SOURCE, it is inside the repository under test, SwiftPM does not
    /// re-verify it once a checkout exists, and it holds build-tool PLUGINS
    /// that the build EXECUTES. Measured before this gate existed, with a
    /// comment-only commit and one `sed` into a dependency's benchmark timer:
    /// `rc 0, verdict keep, ratio 0.0099977, warnings []`.
    ///
    /// Checked on BOTH sides, because both get compiled: the candidate
    /// repository at gate 5, and the pinned worktree at the baseline-side
    /// build. Baseline recorded one merged map because the two are the same
    /// checkouts of the same pinned revisions -- measured byte-identical, 803
    /// files.
    ///
    /// THE MISSING-IS-FINE RULE, and why it is not a hole. A whole dependency
    /// absent from `.build/checkouts` is allowed: SwiftPM re-clones it at the
    /// revision `Package.resolved` names, that file's bytes are hashed by gate
    /// 2a, and git's content addressing means a checkout that IS at that
    /// revision has the real source. So `rm -rf .build` stays a legal thing
    /// for an agent or an operator to do. What is refused is a dependency that
    /// is PRESENT and no longer matches -- a file edited, added or removed
    /// inside it -- because SwiftPM will not repair that, and it is exactly
    /// what changes the compiled result.
    ///
    /// PURE READ, and placed with the other pure reads so that it runs before
    /// gate 3 writes a byte and, far more importantly, before gate 5 starts a
    /// build that would execute a plugin out of this tree.
    static func checkoutIntegrityFailure(
        repo: URL, worktree: URL, record: BaselineRecord
    ) -> GateFailure? {
        guard let recorded = record.checkoutSHA256 else {
            return GateFailure(reason: "baseline_predates_tree_inventory", detail: """
                this baseline record has no inventory of the dependency checkouts under \
                \(BaselineRunner.checkoutsSubpath), because it was written by a version of \
                autor3search-swift from before that existed. That tree is exempt from the \
                out-of-scope inventory and from the dirty-tree gate -- .build/ is excluded from \
                both -- but SwiftPM COMPILES it and does not re-verify it, and a build-tool \
                plugin living there is EXECUTED during the build. Without the inventory a single \
                edit to a dependency's source wins a measurement outright.

                Re-run `autor3search-swift baseline` under a NEW tag to establish one. Results \
                from this run were measured without that protection and should not be mixed with \
                the new run's.
                """)
        }

        for (label, directory) in [("the candidate repository", repo),
                                   ("the pinned measurement worktree", worktree)] {
            let live: [String: String]
            do {
                live = try BaselineRunner.checkoutInventory(in: directory)
            } catch {
                return GateFailure(reason: "dependency_checkout_modified", detail: """
                    could not inventory the dependency checkouts in \(label) at \
                    \(directory.path): \(error). Failing closed -- a check that cannot run is not \
                    a check that passed.
                    """)
            }
            guard !live.isEmpty else { continue }
            if recorded.isEmpty {
                return GateFailure(reason: "dependency_checkout_modified", detail: """
                    \(label) has dependency checkouts under \(BaselineRunner.checkoutsSubpath), \
                    but baseline recorded none, so there is nothing to verify them against. \
                    Refusing rather than compiling unverified dependency source: that tree holds \
                    build-tool plugins the build executes. Re-run `baseline` under a new tag.
                    """)
            }

            // Grouped by dependency, so a WHOLE missing checkout is tolerated
            // (SwiftPM re-clones it from the pin) while a present-but-altered
            // one is refused.
            let present = Set(live.keys.compactMap { BaselineRunner.checkoutDependency(of: $0) })
            var lines: [String] = []
            for path in live.keys.sorted() where recorded[path] == nil {
                lines.append("  added:    \(path) (baseline recorded no such file)")
            }
            for path in recorded.keys.sorted() {
                guard let dependency = BaselineRunner.checkoutDependency(of: path),
                      present.contains(dependency) else { continue }
                if let now = live[path] {
                    if now != recorded[path] {
                        lines.append("  modified: \(path) (now \(now), baseline recorded \(recorded[path]!))")
                    }
                } else {
                    lines.append("  removed:  \(path) (baseline recorded \(recorded[path]!))")
                }
            }
            guard lines.isEmpty else {
                return GateFailure(reason: "dependency_checkout_modified", detail: """
                    the dependency sources in \(label) are no longer the ones \(Lockfile.name) \
                    pins:

                    \(String(lines.joined(separator: "\n").prefix(4000)))

                    \(BaselineRunner.checkoutsSubpath) is SOURCE, not build output. It is exempt \
                    from the out-of-scope inventory and from the dirty-tree gate -- .build/ is \
                    excluded from both, and git collapses it to a single ignored record -- but \
                    SwiftPM compiles it, and does not restore or re-verify it once the checkout \
                    exists. Editing a dependency's benchmark timer there wins a measurement with \
                    a comment-only commit, and a build-tool plugin in that tree is EXECUTED \
                    during the build, so this is also an arbitrary-code-execution surface.

                    Deleting a whole dependency's checkout is fine and is NOT what this is \
                    reporting: SwiftPM re-clones it at the revision \(Lockfile.name) pins, and \
                    that file's own bytes are hashed by gate 2. To recover, delete the affected \
                    checkout (or all of \(BaselineRunner.checkoutsSubpath)) and let SwiftPM \
                    restore it from the pin; the next build will do so automatically. If the \
                    change was intended, it belongs in a dependency version bump, which is a \
                    human decision and requires a new baseline.
                    """)
            }
        }
        return nil
    }

    // MARK: - The build cache, which no inventory can cover

    /// Everything under `.build/` that is COMPILED OUTPUT, as opposed to the
    /// resolved dependency state that `checkoutSHA256` verifies and that
    /// re-creating would need the network.
    ///
    /// Deleting exactly this set gives a cold build WITHOUT a re-resolve:
    /// `checkouts/`, `repositories/` and `artifacts/` survive, so SwiftPM does
    /// not clone anything, and every object, binary and plugin is rebuilt from
    /// sources gates 2a-2d have verified.
    static let buildOutputSubpaths = [
        ".build/out", ".build/debug", ".build/release", ".build/plugins",
        ".build/manifest.pif",
    ]

    /// Where SwiftPM keeps compiled build-tool plugins and the sources they
    /// generate. `cache/` holds Mach-O executables -- verified with `file`:
    /// `.build/plugins/cache/BenchmarkPlugin: Mach-O 64-bit executable arm64`
    /// -- and `outputs/` holds generated Swift that is compiled into the
    /// benchmark.
    static let pluginCacheSubpath = ".build/plugins"

    /// Deletes `subpaths` under `directory`, returning the failure to answer
    /// with or `nil`. A path that is not there is success: the point is that it
    /// is absent afterwards.
    ///
    /// FAIL-CLOSED. A deletion that cannot be performed is a refusal, not a
    /// warning: continuing would build with exactly the cached artifact the
    /// deletion exists to discard, which is the one outcome worse than not
    /// measuring at all.
    static func purge(
        _ subpaths: [String], in directory: URL, reason: String, what: String, where description: String
    ) -> GateFailure? {
        for subpath in subpaths {
            let url = directory.appendingPathComponent(subpath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return GateFailure(reason: reason, detail: """
                    \(what) could not be removed from \(description): \(subpath) (\(error)). \
                    Failing closed -- building on top of it would use exactly the cached artifact \
                    this deletion exists to discard.
                    """)
            }
        }
        return nil
    }

    /// Deletes the compiled build-tool plugins before a build, so they are
    /// recompiled from checkout sources gate 2d has just verified.
    ///
    /// WHY THIS IS NOT COVERED BY ANY INVENTORY. Gate 2d hashes
    /// `.build/checkouts`, which is where a plugin's SOURCE lives. But SwiftPM
    /// compiles that source once and caches the RESULT here, and llbuild
    /// decides whether to recompile from recorded input signatures -- so a
    /// tampered `.build/plugins/cache/BenchmarkPlugin`, whose sources have not
    /// changed, is reused. That binary is executed during the build, after
    /// every integrity gate has passed. Deleting it is the cheap, sound answer:
    /// it needs no hash of a 397 MB tree and it cannot be fooled by whatever
    /// llbuild happens to key on.
    ///
    /// MEASURED, on `Fixtures/DemoPackage` (two `swift build -c release
    /// --product` invocations, the pair an eval runs per side):
    ///
    /// ```
    /// warm, plugins kept      1.673 / 1.677 / 1.845 s
    /// .build/plugins deleted  2.527 / 2.478 / 2.491 s
    /// ```
    ///
    /// ~0.81 s per side, ~1.62 s per eval across both, against a ~39 s eval:
    /// about 4%. The whole directory is removed rather than just `cache/`
    /// (which measured 2.27 s, ~0.22 s cheaper) because `outputs/` holds
    /// plugin-GENERATED Swift that is compiled into the benchmark, and relying
    /// on SwiftPM to regenerate it after only `cache/` is cleared would make
    /// the guarantee depend on a caching detail rather than on absence.
    static func purgePluginCache(in directory: URL, where description: String) -> GateFailure? {
        purge([pluginCacheSubpath], in: directory, reason: "plugin_cache_not_purged",
              what: "the compiled build-tool plugin cache", where: description)
    }

    /// Environment override for the build-output purge. The configured source
    /// of truth is now `Config.purgeBuildOutput` (`purge_build_output` in
    /// `config.yaml`); this is KEPT as an override alongside it, not replaced
    /// by it.
    ///
    /// WHY IT STAYS, now that the config field exists. `config.yaml`'s bytes
    /// are pinned by `configSHA256` at baseline, so turning the purge on for
    /// an EXISTING run means editing a file gate 2 will then refuse, i.e.
    /// re-baselining and throwing away the run's history. That is the correct
    /// default for a criterion the verdict depends on -- `alpha`,
    /// `min_effect_pct` and `scope` must not move mid-run -- but this switch
    /// is not one of those. It changes nothing about how a result is judged;
    /// it only makes the artifact being judged more trustworthy. An operator
    /// who becomes suspicious of a machine at 3am should be able to tighten
    /// the next eval without discarding the fifty experiments before it.
    ///
    /// AN OVERRIDE THAT CAN ONLY TIGHTEN, which is the whole reason it is safe
    /// to read from the environment at all. In many deployments the agent
    /// under measurement is the process that invokes `eval`, so an environment
    /// variable that could WEAKEN a gate would be a gate the agent controls.
    /// This one ORs with the config and has no value that disables anything:
    /// `purge_build_output: true` cannot be switched off from the environment,
    /// and the only thing setting the variable costs the agent is a cold
    /// build. Read `purgeBuildOutput(config:env:)` for the one-line proof.
    ///
    /// The plugin-cache purge deliberately has no switch of either kind.
    public static let purgeBuildOutputEnvKey = "AUTOR3SEARCH_SWIFT_PURGE_BUILD_OUTPUT"

    static func purgeBuildOutputRequested(env: [String: String]) -> Bool {
        guard let raw = env[purgeBuildOutputEnvKey]?.trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Whether to purge the whole build output this eval: the config field OR
    /// the environment override.
    ///
    /// `||`, never `&&` and never "env wins". The environment can only add a
    /// reason to purge, never remove one, so no value of
    /// `AUTOR3SEARCH_SWIFT_PURGE_BUILD_OUTPUT` can undo
    /// `purge_build_output: true`. That is the property that makes it
    /// acceptable for the measured agent to be the process holding the
    /// environment.
    static func purgeBuildOutput(config: Config, env: [String: String]) -> Bool {
        config.purgeBuildOutput || purgeBuildOutputRequested(env: env)
    }

    /// Raised by `MeasuredBinaryGuard` when one of the four executables gate 8
    /// launches has changed since measurement began.
    struct MeasuredBinaryTampered: Error, CustomStringConvertible {
        let detail: String
        var description: String { detail }
    }

    /// Wraps the `MetricSource` and re-hashes the binaries being measured
    /// BEFORE EVERY SAMPLE.
    ///
    /// THE VECTOR. Every gate up to here constrains what the agent may WRITE.
    /// None of them constrains what the agent's benchmark DOES once the harness
    /// runs it -- and it runs as the same uid, on the same filesystem, with the
    /// pinned worktree at a path it can compute. Measured, from a commit whose
    /// entire diff is one in-scope source file holding the ORIGINAL quadratic
    /// algorithm plus a lazily-initialised global:
    ///
    /// ```
    /// attacked: rc 0  keep  ratio 0.04973  baseline 73.30 ms  candidate 3.65 ms  warnings []
    /// ```
    ///
    /// The initialiser rewrote the pinned worktree's benchmark to 35000 repeats
    /// and rebuilt it, so every later baseline sample measured an inflated
    /// binary. On KEEP the worktree source was git-restored, erasing the trace,
    /// and the inflated BINARY survived: the next, entirely honest eval came
    /// back `rc 0 keep ratio 0.05069` against a 71.34 ms baseline. That is the
    /// stale-baseline coasting bug this project exists to prevent, reached
    /// through a door no gate was watching.
    ///
    /// It defeats gate 7 by TOCTOU. The worktree is verified, restored and
    /// built before candidate code runs, and was never looked at again.
    ///
    /// PER SAMPLE, NOT PER EVAL, and the interval is the whole design:
    ///
    /// - A check only at the END is beaten by sabotage-measure-restore: inflate
    ///   the baseline, let the slow samples run, put the binary back.
    /// - A check only at the START is beaten by sabotaging afterwards, which is
    ///   exactly what this attack does.
    /// - `MeasureSession` interleaves baseline/candidate within every round, so
    ///   even a check after the last candidate sample leaves nine rounds
    ///   unguarded.
    ///
    /// Checking before each sample bounds the damage to nothing: the sample
    /// about to be taken is taken against bytes that were just verified.
    ///
    /// COST, measured: the four binaries total 17.2 MB on the demo package and
    /// hash in 5.4 ms, so `count: 10` with one benchmark -- 20 counted samples
    /// plus 2 warm-ups, 22 checks -- costs about 119 ms against a ~39 s eval,
    /// or 0.3%. No compromise on the interval was needed.
    ///
    /// ALL FOUR BINARIES ON EVERY CHECK, not just the side about to run.
    /// Checking only the sampled side would be sound given the interleave, and
    /// half the cost; at 119 ms the simpler invariant -- "nothing that will be
    /// measured has changed since measurement began" -- is worth more than the
    /// 60 ms.
    ///
    /// A binary that is ABSENT at snapshot time is not recorded, which keeps
    /// every test that injects its own `MetricSource` working (they have no
    /// `.build/release` at all). A binary that was recorded and is then missing
    /// IS a violation: deleting the baseline binary mid-measurement is as good
    /// to an attacker as rewriting it.
    final class MeasuredBinaryGuard: MetricSource, @unchecked Sendable {
        private let inner: any MetricSource
        private let expected: [(url: URL, digest: String)]

        /// The first violation seen, kept because `warmUp` deliberately
        /// converts a throwing sample into a warning -- so without this the
        /// warm-up phase would swallow a detection.
        private(set) var violation: String?
        private(set) var checks = 0

        /// Hashes the binaries that exist. SEPARATE FROM THE INITIALISER so the
        /// snapshot can be taken at the moment the last build finishes, rather
        /// than wherever the guard happens to be constructed -- the two were
        /// the same place until an agent's `core.fsmonitor` rewrote a binary in
        /// between and the guard adopted the tampered hash as its baseline.
        static func digests(of binaries: [URL]) -> [(url: URL, digest: String)] {
            binaries.compactMap { url in
                guard let digest = try? BaselineRunner.sha256File(url) else { return nil }
                return (url: url, digest: digest)
            }
        }

        init(wrapping inner: any MetricSource, binaries: [URL]) {
            self.inner = inner
            self.expected = MeasuredBinaryGuard.digests(of: binaries)
        }

        init(wrapping inner: any MetricSource, digests: [(url: URL, digest: String)]) {
            self.inner = inner
            self.expected = digests
        }

        var guardedCount: Int { expected.count }

        /// `nil` when every recorded binary still hashes to what it did.
        func check() -> String? {
            checks += 1
            for entry in expected {
                let now = try? BaselineRunner.sha256File(entry.url)
                guard now != entry.digest else { continue }
                return """
                    \(entry.url.path) \
                    (\(now.map { "now sha256 \($0)" } ?? "the file is gone"), was \(entry.digest))
                    """
            }
            return nil
        }

        func sample(benchmark: String, in worktree: URL, config: Config) throws -> Double {
            if let offender = check() {
                if violation == nil { violation = offender }
                throw MeasuredBinaryTampered(detail: offender)
            }
            return try inner.sample(benchmark: benchmark, in: worktree, config: config)
        }
    }

    /// The two executables gate 8 launches out of ONE side: the benchmark
    /// target and `BenchmarkTool`.
    ///
    /// Per-side, because each side is snapshotted immediately after ITS OWN
    /// build and the two builds are far apart in the gate chain -- gate 5 for
    /// the candidate, gate 7 for the baseline -- with `swift test` in between.
    static func measuredBinaries(in directory: URL, benchmarkTarget: String) -> [URL] {
        [benchmarkTarget, "BenchmarkTool"].map {
            directory.appendingPathComponent(".build/release/\($0)")
        }
    }

    /// The four executables gate 8 launches, both sides.
    static func measuredBinaries(
        baselineWorktree: URL, candidateWorktree: URL, benchmarkTarget: String
    ) -> [URL] {
        measuredBinaries(in: baselineWorktree, benchmarkTarget: benchmarkTarget)
            + measuredBinaries(in: candidateWorktree, benchmarkTarget: benchmarkTarget)
    }

    /// Deletes the measured binaries on both sides, so a poisoned one cannot
    /// survive into the next eval.
    ///
    /// DETECTION IS NOT ENOUGH ON ITS OWN. The measured attack left an inflated
    /// baseline binary behind, and the NEXT, entirely honest eval inherited it
    /// and returned an unearned KEEP -- because SwiftPM had already recorded
    /// that binary as up to date for the restored source. Removing them forces
    /// the next build to produce them again from sources every gate has
    /// verified.
    static func discardMeasuredBinaries(
        baselineWorktree: URL, candidateWorktree: URL, benchmarkTarget: String
    ) {
        for url in measuredBinaries(
            baselineWorktree: baselineWorktree, candidateWorktree: candidateWorktree,
            benchmarkTarget: benchmarkTarget) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Gate 2e. Tracked files must hold the bytes the commit records -- checked
    /// by hashing them, not by asking git.
    ///
    /// THE FIFTEENTH, found by attacking a key the denial list cannot cover.
    /// `filter.<name>.clean` is per-name, so `-c` cannot deny it wholesale, and
    /// git runs it on every `status` to decide whether a worktree file is
    /// modified. Put the FAST implementation in the working tree and a clean
    /// filter that always emits the COMMITTED bytes, and `status` reports a
    /// clean tree while `swift build` compiles the fast code. Gate 2c
    /// deliberately EXEMPTS in-scope paths -- in-scope content is what the agent
    /// is supposed to change -- so nothing was looking. Measured:
    /// `rc 0 keep ratio 0.11637` from a repository whose only commit was a
    /// `.gitattributes` and whose `git status --porcelain` was empty.
    ///
    /// ONE MEASURED SUBTLETY, kept because it decides whether the vector is
    /// narrow: git's `status` uses the index's stat SIZE as a fast path and
    /// calls a filtered file modified whenever the size differs, WITHOUT
    /// consulting the filter. So the attack only works when the edit preserves
    /// the file's byte length -- which is one padding comment away, and
    /// therefore narrows nothing at all.
    ///
    /// The answer is the one round 5 established for the worktree, applied to
    /// the candidate: stop asking git about content and hash it.
    /// `Worktree.contentMismatches` reads blob ids out of the commit object and
    /// hashes the bytes on disk itself, so no filter, attribute or config
    /// participates.
    ///
    /// PLACED AFTER GATE 2c, not before. An out-of-scope tracked file hidden by
    /// `--assume-unchanged` is a content mismatch too, and gate 2c answers it
    /// with `out_of_scope` -- the more precise diagnosis, and the one the frozen
    /// tests pin. What reaches here is what 2c does not look at: IN-SCOPE
    /// content, which is exactly the fifteenth.
    static func trackedContentFailure(git: Git, repo: URL) -> GateFailure? {
        guard let head = try? git.head(), !head.isEmpty else { return nil }
        let mismatches = (try? Worktree.contentMismatches(at: repo, commit: head)) ?? []
        guard !mismatches.isEmpty else { return nil }
        return GateFailure(reason: "dirty_working_tree", detail: """
            tracked files do not match the bytes recorded at HEAD (\(head)), even though \
            `git status` reports the tree as clean: \
            \(mismatches.prefix(20).joined(separator: "; ")). A `.gitattributes` entry plus a \
            `filter.<name>.clean` in .git/config makes git compare a rewritten copy back as \
            though it were unchanged, so an uncommitted edit can be compiled and measured while \
            every path-based gate sees nothing. The pinned measurement worktree is a checkout of \
            a COMMIT and cannot contain it, so such an edit would manufacture a win on every \
            later experiment, credited to commits that do not contain it. This check hashes the \
            bytes against the commit's own blob ids and asks git nothing. Commit the change, or \
            discard it.
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
                stopRequested: stopRequested, source: source, env: env)
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
        stopRequested: Bool, source: (any MetricSource)?, env: [String: String]
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
        // IGNORED FILES COUNT. `git status --porcelain` alone omits them, and
        // that omission is a bypass in its own right -- see `dirtyTreeFailure`,
        // which carries the full reasoning and the allowlist.
        if let failure = dirtyTreeFailure(git: git, repo: repo, record: record) {
            return fail(failure)
        }

        // ---- Gate 2c: `scope`, enforced against the DISK ----
        //
        // THE ROOT CAUSE, stated once. Gate 1 derives what changed from GIT's
        // view; gate 2b derives cleanliness from GIT's view; SwiftPM compiles
        // THE DISK; and the agent controls git's view. Gate 2a already closed
        // that gap for manifests by hashing them. This closes it for
        // everything else outside `scope`. See `treeInventoryFailure`.
        //
        // `config.scope` is safe to use here, and would not have been safe
        // anywhere above gate 2: the config's bytes were verified against
        // `configSHA256` there, so this is provably the same `scope` list
        // `baseline` took the inventory at. Reading `scope` from an unverified
        // config would reopen the gate this closes.
        //
        // PLACEMENT, and it is deliberate: AFTER gate 2b, not before. An
        // out-of-scope file that is merely UNCOMMITTED is caught by both, and
        // the frozen test `aDirtyWorkingTreeIsRefusedBeforeAnythingIsMeasured`
        // pins `dirty_working_tree` as the answer for that case -- the more
        // actionable one, since the operator's next move is to commit or
        // discard rather than to re-baseline. What reaches this gate is what
        // gate 2b could not see at all, which is the whole point of it.
        //
        // Still a pure read, so gate 3's first write and gate 5's first build
        // are both still downstream of every rejection above.
        if let failure = treeInventoryFailure(repo: repo, record: record, scope: config.scope) {
            return fail(failure)
        }

        // ---- Gate 2e: tracked content, hashed rather than asked about ----
        //
        // After 2c on purpose: an out-of-scope file hidden by an index flag is
        // also a content mismatch, and 2c gives it the better name. What is
        // left for this gate is an IN-SCOPE lie, which 2c deliberately does not
        // look at. See `trackedContentFailure`.
        if let failure = trackedContentFailure(git: git, repo: repo) {
            return fail(failure)
        }

        // ---- Gate 2d: the dependency sources about to be compiled ----
        //
        // The same root cause a third time, through the one door the two
        // inventories above deliberately leave shut: `.build/`. That
        // exemption is right for build OUTPUT and wrong for
        // `.build/checkouts`, which is dependency SOURCE that SwiftPM
        // compiles, never re-verifies, and -- in the case of a build-tool
        // plugin -- EXECUTES. See `checkoutIntegrityFailure`.
        //
        // Before gate 3's first write and, critically, before gate 5's build.
        let pinnedWorktree = try home.worktreeURL(tag: tag)
        if let failure = checkoutIntegrityFailure(
            repo: repo, worktree: pinnedWorktree, record: record) {
            return fail(failure)
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

        // ---- Gate 4b: discard the caches no inventory can vouch for ----
        //
        // Gate 2d hashes `.build/checkouts`, which is where a build-tool
        // plugin's SOURCE lives. SwiftPM compiles that source once and caches
        // the RESULT in `.build/plugins`, and llbuild decides whether to
        // recompile from recorded input signatures -- so a tampered
        // `.build/plugins/cache/BenchmarkPlugin` (verified with `file` to be a
        // Mach-O executable) whose sources have not changed is REUSED, and it
        // is executed during the build below, after every integrity gate has
        // passed. No inventory can close that: the artifact is legitimately
        // rewritten by every build.
        //
        // So it is deleted instead, on both sides, every eval. Measured at
        // ~0.81 s per side on the demo package -- about 4% of a ~39 s eval --
        // against a cold build of the whole output tree at ~18 s per side.
        // See `purgePluginCache`.
        let purgeOutput = purgeBuildOutput(config: config, env: env)
        for (directory, description) in [(repo, "the candidate repository"),
                                         (try home.worktreeURL(tag: tag),
                                          "the pinned measurement worktree")] {
            if purgeOutput {
                // OPT-IN, default off. Deletes every compiled artifact, not
                // just the plugins, so the measured binaries are built entirely
                // from verified sources. `checkouts/`, `repositories/` and
                // `artifacts/` survive, so this is a cold BUILD and not a
                // re-resolve: no network, nothing re-cloned. Measured at
                // ~18 s per side on the demo package, which roughly doubles
                // the cost of an experiment -- which is why it is not the
                // default and why the residual is documented instead.
                if let failure = purge(
                    buildOutputSubpaths, in: directory, reason: "build_output_not_purged",
                    what: "the compiled build output", where: description) {
                    return fail(failure)
                }
            } else if let failure = purgePluginCache(in: directory, where: description) {
                return fail(failure)
            }
        }

        let timeout = TimeInterval(config.timeoutSeconds)

        let build = try Subprocess.run(swift, ["build", "-c", "release"], cwd: repo,
                                       env: SanitizedEnvironment.forTools(), timeout: timeout)
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

        // ---- THE CANDIDATE SIDE IS SNAPSHOTTED HERE, BEFORE GATE 6 ----
        //
        // Round 9 moved the snapshot to sit immediately after the last BASELINE
        // build, on the principle that nothing able to run a program may sit
        // between a build and the snapshot that vouches for it. That principle
        // was applied to one side only, and the other side had a bigger hole:
        // gate 6 below runs `swift test`, which is THE AGENT'S CODE BY
        // CONSTRUCTION, and the candidate's binaries were not snapshotted until
        // long after it.
        //
        // Measured 4/4 at shipped defaults, with an in-scope commit whose
        // `countWords` is the byte-identical quadratic original plus a lazy
        // global that fires only when `argv[0]` is not under `/release/` -- i.e.
        // during the test phase -- and copies a pre-staged fast `Bench` over
        // `<repo>/.build/release/Bench`:
        //
        //     rc 0  keep  k 1  ratio 0.11086  p 1.0825e-05  warnings []
        //
        // The guard then hashed the SWAPPED binary and adopted it as its own
        // reference, so every per-sample check matched. The tree was byte-clean
        // and all nine gates passed.
        //
        // `purge_build_output` did not close it and could not: it purges at
        // gate 4b, BEFORE the build, so it discards a poisoned artifact from a
        // previous eval and has nothing to say about one written during this
        // one.
        //
        // Snapshotting here rather than re-verifying after the tests: the two
        // detect the same thing, but this way each side's reference is taken at
        // the only moment it is known good -- the instant its build finished --
        // and there is one rule for both sides instead of a rule and an
        // exception. Nothing legitimately rewrites these two files between here
        // and gate 8: `swift test` builds DEBUG products, and the only other
        // builds are the baseline side's, in a different directory.
        let candidateDigests = MeasuredBinaryGuard.digests(
            of: measuredBinaries(in: repo, benchmarkTarget: config.benchmarkTarget))

        let tests = try Subprocess.run(swift, ["test"], cwd: repo,
                                       env: SanitizedEnvironment.forTools(), timeout: timeout)
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
        // RESTORE FIRST, THEN VERIFY -- the reverse of what this was, and the
        // reversal is a bug fix. A pre-restore `verify` that refuses runs
        // BEFORE the restore whose whole job is to repair the thing it refused
        // over, so any tampering that `verify` could see bricked the run
        // permanently: measured, an eval and every eval after it returning
        // `worktree_integrity` with the worktree still dirty, because the
        // repair never got the chance to run. The worktree's correct contents
        // are known exactly -- it is a checkout of `measurementCommit` and
        // nothing else -- so repairing is always the right move, and
        // `restoreToPin` ends by verifying its own work.
        let worktree = pinnedWorktree

        var warnings: [String] = []

        // ---- Gate 7b: and `verify` asks GIT, so RESTORE rather than trust ----
        //
        // `Worktree.verify` reads `git status`, which is the same oracle the
        // rest of this file has now stopped trusting three times over. The
        // agent can reach this worktree with a shell:
        //
        //     git -C <worktree> update-index --assume-unchanged <a helper>
        //     <edit it: the benchmark's workload 1750 -> 17500>
        //
        // `status` is then empty, `verify` returns true, and the baseline-side
        // build below compiles the edit -- so the BASELINE is made slower and a
        // comment-only commit measures as a win. Measured: `rc 0, keep,
        // ratio 0.09997`. The README presented gate 7 as an integrity check, so
        // either it does its job or the claim goes.
        //
        // The answer here is not another detector. This worktree is
        // harness-owned state whose correct contents are known exactly -- it is
        // a checkout of `measurementCommit` and nothing else -- so it is simply
        // RESTORED, unconditionally, every eval, before the build that reads
        // it. `restoreToPin` clears the index flags first (measured: `checkout
        // --force` alone does NOT undo `--skip-worktree`) and then forces the
        // checkout. Repairing rather than refusing also denies the agent a
        // one-line denial of service; the cleared paths become a warning a
        // human sees.
        //
        // NO STALE-BINARY REGRESSION. This restores SOURCE and leaves `.build`
        // alone (`clean -fd`, never `-fdx`), and the per-eval baseline-side
        // rebuild immediately below still runs, by product name, exactly as
        // before. A forced checkout of the commit already checked out rewrites
        // nothing, so the warm cache stays valid; if the worktree HAD been
        // tampered with, the restore changes the source back and the rebuild
        // below recompiles it. Either way the binary measured is the binary of
        // `measurementCommit`.
        do {
            let flagged = try Worktree.restoreToPin(
                git: git, at: worktree, to: record.measurementCommit)
            if !flagged.isEmpty {
                warnings.append("""
                    the pinned measurement worktree had \(flagged.count) path(s) marked \
                    --assume-unchanged or --skip-worktree in its index, which hides edits to them \
                    from `git status` and therefore from the worktree-integrity gate, while the \
                    baseline-side build still compiles them: \
                    \(flagged.map { "\($0.tag) \($0.path)" }.prefix(20).joined(separator: ", ")). \
                    The flags were cleared and the worktree was restored to \
                    \(record.measurementCommit) before anything was built or measured, so this \
                    experiment's numbers are sound -- but nothing legitimate sets those flags on \
                    a harness-owned worktree, and it is worth finding out what did.
                    """)
            }
        } catch {
            return fail(GateFailure(reason: "worktree_integrity", detail: """
                the pinned measurement worktree at \(worktree.path) could not be restored to \
                \(record.measurementCommit) before measuring: \(error). Failing closed -- the \
                baseline side is what every ratio is divided by, so measuring against a worktree \
                whose contents cannot be established is worse than not measuring at all.
                """))
        }
        // An ignored file planted in the worktree survives `clean -fd`, and
        // `.git/info/exclude` is SHARED between the main repository and its
        // worktrees -- so the agent can write the rule without touching any
        // file the worktree contains. Unlike the repository under test, this
        // directory has an exactly-known legitimate content: a checkout plus
        // the harness's own `.build`. Anything else ignored here is a refusal,
        // with no inventory needed.
        if let entries = try? Git(repo: worktree).status(includingIgnored: true) {
            let strays = entries.filter {
                $0.isIgnored && !BaselineRunner.isHarnessOutput($0.path)
            }
            guard strays.isEmpty else {
                return fail(GateFailure(reason: "worktree_integrity", detail: """
                    the pinned measurement worktree at \(worktree.path) contains files that an \
                    ignore rule hides from git and that the harness did not put there: \
                    \(strays.map(\.path).joined(separator: ", ")). `git clean -fd` does not \
                    remove ignored files and `-fdx` would delete the warm build cache, so these \
                    are refused rather than swept away. Note that .git/info/exclude is SHARED \
                    between a repository and its worktrees, so the rule may not live in any file \
                    this worktree contains. The only ignored paths expected here are the \
                    harness's own: \
                    \(BaselineRunner.harnessOutputDirectories.map { $0 + "/" }.joined(separator: ", ")).
                    """))
            }
        }

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
            swift, ["build", "-c", "release"], cwd: worktree,
            env: SanitizedEnvironment.forTools(), timeout: timeout)
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

        // ---- THE SNAPSHOT IS TAKEN HERE, NOT AT GATE 8 ----
        //
        // This is the last line that builds anything. Everything between here
        // and the first sample -- the `isClean` below, a possible `repoint`,
        // the unsafe scan's `git show` per changed path -- RUNS GIT, and git
        // runs programs the repository's own config can name.
        //
        // That window was a live bypass, not a tidiness point. An agent's
        // `core.fsmonitor` fired inside the post-build `status --porcelain`
        // immediately below and overwrote the worktree's benchmark binary with
        // a pre-built inflated one. The guard then hashed the ALREADY-INFLATED
        // binary, every per-sample re-check matched it, and
        // `measured_binary_changed` never fired: `rc 0 keep ratio 0.0496`,
        // baseline 71.7 ms against an honest 3.6 ms. Only `.build` was touched,
        // so the worktree stayed clean and gate 7 passed.
        //
        // `core.fsmonitor` is denied now (see `Git.executionDenials`), but a
        // snapshot whose correctness depends on a denial list being complete is
        // a snapshot in the wrong place. Taken here it predates every one of
        // those git calls, so anything they change is a MISMATCH the guard
        // reports rather than a value it adopts. Same rule as round 5, applied
        // to the snapshot instead of the check: take it after the last thing
        // that legitimately changes it, not after the last thing that happens.
        //
        // SYMMETRY: the candidate's half was taken at gate 5, the instant ITS
        // build finished and before `swift test` ran the agent's code. Only the
        // baseline's half is taken here, and the two are combined. Re-hashing
        // the candidate here instead would re-adopt whatever gate 6 left
        // behind, which is exactly the sixteenth vector.
        let measuredBinaryDigests = candidateDigests + MeasuredBinaryGuard.digests(
            of: measuredBinaries(in: worktree, benchmarkTarget: config.benchmarkTarget))

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
        // ---- Gate 8a: the binaries must not change WHILE they are measured ----
        //
        // Everything above constrains what the agent may WRITE. Nothing
        // constrains what the agent's BENCHMARK DOES once this harness runs
        // it -- same uid, same filesystem, and the pinned worktree at a path it
        // can compute. Measured: a commit whose whole diff is one in-scope file
        // holding the ORIGINAL quadratic algorithm, plus a lazily-initialised
        // global that rewrote the worktree's benchmark to 35000 repeats and
        // rebuilt it, returned `rc 0 keep ratio 0.04973` against a 73.30 ms
        // baseline, with no warnings -- and left the inflated binary behind for
        // the next, honest eval to inherit.
        //
        // Gate 7 cannot catch it: it verifies, restores and builds the worktree
        // BEFORE any candidate code runs, and never looks again. The fix is the
        // rule round 5 established -- sample a post-condition after the last
        // thing that can change it -- applied to the one thing that had none:
        // the bytes being measured, re-checked before EVERY sample. See
        // `MeasuredBinaryGuard` for why per-sample and not per-eval.
        // The digests were taken immediately after the last build, BEFORE the
        // git calls that sit between it and here -- see the comment at that
        // line for the fsmonitor attack that made the difference measurable.
        let guarded = MeasuredBinaryGuard(wrapping: metric, digests: measuredBinaryDigests)

        /// A detection is deliberate tampering, not a flake, so it is handled
        /// exactly as a refused frozen restore is: the poisoned binaries are
        /// DELETED (detection alone let the stale one survive into the next
        /// eval) and the run is durably tainted, so nothing further is measured
        /// until a human has looked.
        func measuredBinaryTampering(_ offender: String) -> Verdict {
            discardMeasuredBinaries(
                baselineWorktree: worktree, candidateWorktree: repo,
                benchmarkTarget: config.benchmarkTarget)
            let detail = """
                a binary being measured changed while it was being measured: \(offender). \
                Nothing constrains what the candidate's benchmark does once it is launched -- it \
                runs as the same user, on the same filesystem, and the pinned measurement \
                worktree is at a path it can compute -- so a benchmark that rewrites and rebuilds \
                the BASELINE binary makes doing nothing look like a win, and leaves the inflated \
                binary behind for the next experiment to inherit. The hashes of all \
                \(guarded.guardedCount) measured executables are taken before measurement begins \
                and re-checked before every sample; this one did not match. Both sides' measured \
                binaries have been deleted so the next eval rebuilds them from verified sources, \
                and this run is now tainted: nothing further will be measured until \
                \(RunTaint.url(runDir: runDir).path) is deleted by hand.
                """
            RunTaint.record(runDir: runDir, detail: detail)
            return fail(GateFailure(reason: "measured_binary_changed", detail: detail))
        }

        warnings += warmUp(benchmarks: config.benchmarks, baselineWorktree: worktree,
                           candidateWorktree: repo, source: guarded, config: config)
        // `warmUp` turns a throwing sample into a warning on purpose, so the
        // guard records its own first violation and it is read back here rather
        // than being swallowed with it.
        if let offender = guarded.violation { return measuredBinaryTampering(offender) }

        let samples: [BenchmarkSamples]
        do {
            samples = try MeasureSession.run(
                benchmarks: config.benchmarks, baselineWorktree: worktree,
                candidateWorktree: repo, source: guarded, config: config)
        } catch let tampering as MeasuredBinaryTampered {
            return measuredBinaryTampering(tampering.detail)
        }

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
                cwd: directory, env: SanitizedEnvironment.forTools(), timeout: timeout)
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
