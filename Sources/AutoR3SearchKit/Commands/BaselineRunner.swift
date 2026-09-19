// Sources/AutoR3SearchKit/Commands/BaselineRunner.swift
//
// `baseline` freezes the success criteria and pins the measurement point. It
// records two commits that must never be conflated (see `BaselineRecord`):
// `frozenCommit` (what the frozen files and the scope gate always compare
// against; never advances) and `measurementCommit` (what timings are
// measured against; advances on every KEEP, starting equal to
// `frozenCommit`). This file only ever writes them equal -- Task 17 owns the
// advance.
import Foundation
import Crypto

public enum BaselineError: Error, CustomStringConvertible, Equatable {
    /// The repository under test has uncommitted changes.
    case dirtyTree

    /// `tag` already has a completed baseline.
    case tagInUse(String)

    /// The run branch `autor3search-swift/<tag>` already exists, but not at
    /// the repository's current HEAD. This happens when an earlier attempt
    /// at this tag created the branch but never finished (no `baseline.json`
    /// was written -- see `tagInUse`) and the repository has since moved on.
    /// Checking out the stale branch tip and freezing THAT commit, instead
    /// of the operator's current HEAD, would silently pin the wrong commit
    /// and still report success.
    case staleRunBranch(tag: String, branchCommit: String, headCommit: String)

    /// `swift package describe` did not succeed. Fatal, not a warning: this
    /// is the one call that tells `baseline` which directories to freeze,
    /// and it fails for reasons that have nothing to do with an agent
    /// tampering with a frozen file -- transient network loss (it must
    /// resolve dependencies), a renamed or unreachable dependency, expired
    /// credentials for a private one, a toolchain mismatch, or an agent
    /// that broke `Package.swift` between `init` and `baseline`. Continuing
    /// past this with an empty directory list would freeze nothing and
    /// still report success on exactly the run where establishing real
    /// protection matters most.
    case packageDescribeFailed(String)

    /// A directory `swift package describe` reported as a test or benchmark
    /// target does not exist on disk. `FrozenSnapshot` silently skips a
    /// missing directory (it just enumerates nothing there), so without this
    /// check an operator typo -- or a target whose path moved -- would
    /// freeze less than intended and `baseline` would report success anyway.
    /// "Missing" is categorically different from "exists and is empty",
    /// which is fine and not refused here.
    case missingFrozenDirectory(String)

    /// Freezing the package's described test and benchmark directories
    /// produced zero protected files. Weaker than `missingFrozenDirectory`:
    /// even when every named directory genuinely exists, zero frozen files
    /// means nothing is protected and every later KEEP/DISCARD verdict is
    /// meaningless -- the same outcome Task 6 already refuses for a
    /// symlinked frozen directory, for the same reason. Unconditional: this
    /// check runs on every successful `describe`, with no exemption for any
    /// other path.
    case emptyFreezeManifest

    /// A file that must be hashed is not there. Previously `sha256File`
    /// answered "the hash of zero bytes" for this, which is how "this
    /// repository has no `Package.resolved`" became indistinguishable from
    /// "this repository's `Package.resolved` is empty" -- a well-formed
    /// 64-hex pin that pins nothing at all, recorded without a word of
    /// complaint. Missing and empty are different states and this makes them
    /// different outcomes.
    case missingFileForHash(String)

    /// The package has an external dependency set SwiftPM pins in
    /// `Package.resolved`, and there is no `Package.resolved` to pin it.
    ///
    /// Refused rather than recorded as "absent", because an unpinned
    /// dependency set defeats the purpose of gate 2 -- the agent could win by
    /// changing a dependency -- and because the first `eval`'s own build
    /// CREATES the file, after which every experiment is permanently
    /// `manifest_change_rejected` (if the agent commits it) or
    /// `dirty_working_tree` (if it does not), with no way out, since
    /// `frozenCommit` never advances.
    case unpinnedDependencies(identities: [String])

    /// A `Package.resolved` is on disk but git is not tracking it -- almost
    /// always because it is named in `.gitignore`, which is what `doctor`
    /// itself used to recommend. An ignored lockfile is not pinned by
    /// anything: it is absent from `frozenCommit`, so every later worktree
    /// checkout resolves its own, and the hash recorded here describes a file
    /// no subsequent run is guaranteed to see.
    case lockfileNotTracked

    /// Whether this package needs a lockfile could not be established --
    /// `swift package resolve` failed to run or exited non-zero (no network,
    /// a private dependency without credentials, an unreachable URL). Failing
    /// closed, because the alternative is to record "no dependencies to pin"
    /// on the strength of a check that never ran, which is the exact class of
    /// silent-success failure this project has been bitten by repeatedly.
    case dependencyPinUndetermined(String)

    /// The manifest inventory could not be built. Fatal for the same reason
    /// `packageDescribeFailed` is: a baseline that records an EMPTY inventory
    /// because the scan could not run protects nothing, and reports success.
    case manifestInventoryFailed(String)

    /// The out-of-scope tree inventory could not be built. Fatal for exactly
    /// the same reason `manifestInventoryFailed` is: a baseline that records
    /// an EMPTY inventory because the walk could not run protects nothing and
    /// reports success.
    case treeInventoryFailed(String)

    /// The inventory of present-but-ignored files could not be built. Fatal
    /// for the same reason the other two are: recording an empty one because
    /// the walk could not run would let every later eval read "nothing was
    /// ignored at baseline", which turns a pre-existing ignored file into an
    /// apparent removal and a planted one into an apparent nothing.
    case ignoredInventoryFailed(String)

    /// The dependency-checkout inventory could not be built. Fatal for the
    /// same reason the others are, and with a sharper edge: the tree it covers
    /// contains build-tool plugins, which SwiftPM EXECUTES during the build.
    case checkoutInventoryFailed(String)

    public var description: String {
        switch self {
        case .dirtyTree:
            return """
            working tree is dirty. baseline pins frozenCommit to a specific git SHA -- an \
            uncommitted edit is not reachable from any SHA, so a baseline taken against what \
            is on disk rather than what is in git would not be reproducible. Commit or stash \
            first.
            """
        case .tagInUse(let t):
            return "tag \(t) already has a baseline; choose another"
        case .staleRunBranch(let tag, let branchCommit, let headCommit):
            return """
            refusing to establish baseline \(tag): the run branch autor3search-swift/\(tag) \
            already exists at \(branchCommit), which is not the current HEAD (\(headCommit)). \
            An earlier attempt at this tag likely created the branch and did not finish. \
            Reusing the stale branch tip would silently pin the wrong commit and still report \
            success. Delete or reset the branch, or choose a different tag, and retry.
            """
        case .packageDescribeFailed(let message):
            return """
            refusing to establish a baseline: swift package describe failed (\(message)). \
            Continuing with no directories to freeze would report success while protecting \
            nothing -- exactly the failure this check exists to prevent. Fix the package \
            manifest (the same one swift build needs) and retry.
            """
        case .missingFrozenDirectory(let path):
            return """
            refusing to establish a baseline: \(path) was reported as a test or benchmark \
            target directory but does not exist on disk. Freezing would silently protect less \
            than intended and still report success. Check for a typo in the package manifest, \
            or a target whose path moved.
            """
        case .emptyFreezeManifest:
            return """
            refusing to establish a baseline: freezing the package's test and benchmark \
            directories produced zero protected files. Zero frozen files means nothing is \
            protected, and every later KEEP/DISCARD verdict would be meaningless. Either the \
            package has no test or benchmark targets (add one and re-run init), or every \
            frozen directory is empty.
            """
        case .missingFileForHash(let path):
            return """
            refusing to establish a baseline: \(path) does not exist, so there is nothing to \
            hash. Recording the hash of zero bytes here would look exactly like a real pin while \
            pinning nothing -- "missing" and "empty" must not be the same 64 hex characters.
            """
        case .unpinnedDependencies(let identities):
            let named = identities.isEmpty
                ? ""
                : " (declared dependencies: \(identities.joined(separator: ", ")))"
            return """
            refusing to establish a baseline: this package resolves external dependencies\(named) \
            but has no \(Lockfile.name). baseline pins that file's hash so the dependency set \
            cannot move mid-run -- gate 2 exists precisely so the agent cannot win by changing a \
            dependency -- and with no lockfile there is nothing to pin.

            This is not a cosmetic refusal. `swift package describe` does not write \
            \(Lockfile.name), but `swift build` does, into the package root -- so the FIRST eval \
            would create it, and from then on every experiment would fail permanently: \
            manifest_change_rejected if the agent commits it, dirty_working_tree if it does not. \
            frozenCommit never advances, so neither door reopens.

            Fix: run `autor3search-swift init` (which now runs `swift package resolve` and \
            commits the result), or by hand:

              swift package resolve && git add \(Lockfile.name) && git commit -m "pin dependencies"

            Do NOT add \(Lockfile.name) to .gitignore. That silences the symptom and leaves every \
            dependency unpinned forever.
            """
        case .lockfileNotTracked:
            return """
            refusing to establish a baseline: \(Lockfile.name) exists on disk but git is not \
            tracking it -- check whether .gitignore names it. An ignored lockfile is pinned by \
            nothing: it is absent from frozenCommit, so every later worktree checkout resolves \
            its own, and the hash recorded here would describe a file no subsequent run is \
            guaranteed to see.

            Fix: remove \(Lockfile.name) from .gitignore, then \
            `git add \(Lockfile.name) && git commit -m "pin dependencies"`.
            """
        case .dependencyPinUndetermined(let why):
            return """
            refusing to establish a baseline: could not determine whether this package needs a \
            \(Lockfile.name), because `swift package resolve` did not succeed (\(why)).

            Treating that as "no dependencies to pin" would record a baseline on the strength of \
            a check that never ran. Fix whatever stopped the resolve -- network, credentials for \
            a private dependency, an unreachable dependency URL, a broken manifest -- and retry.
            """
        case .manifestInventoryFailed(let why):
            return """
            refusing to establish a baseline: could not inventory this repository's manifests \
            (\(why)).

            baseline records the hash of every Package.swift, Package.resolved, version-specific \
            manifest and .swiftpm file in the tree, and eval compares the bytes on disk against \
            it -- that is what stops a nested manifest being rewritten behind git's back. \
            Recording an empty inventory because the scan could not run would protect nothing and \
            still report success.
            """
        case .treeInventoryFailed(let why):
            return """
            refusing to establish a baseline: could not inventory the files outside this \
            repository's configured scope (\(why)).

            baseline records the SHA-256 of every file the agent is not allowed to change, and \
            eval walks the disk and compares -- that is what stops an out-of-scope benchmark \
            helper being edited behind git's back with `git update-index --assume-unchanged`. \
            Recording an empty inventory because the walk could not run would protect nothing and \
            still report success.
            """
        case .ignoredInventoryFailed(let why):
            return """
            refusing to establish a baseline: could not inventory the files an ignore rule is \
            hiding from git (\(why)).

            baseline records those files' hashes so that eval can tell a file that was ALREADY \
            there -- part of the honest starting point -- from one PLANTED after the freeze, \
            which the pinned measurement worktree can never contain and which would therefore \
            manufacture a win on every later experiment. Recording an empty inventory because the \
            walk could not run would erase that distinction in the dangerous direction.
            """
        case .checkoutInventoryFailed(let why):
            return """
            refusing to establish a baseline: could not inventory the dependency checkouts under \
            \(BaselineRunner.checkoutsSubpath) (\(why)).

            That tree is SOURCE, not build output: SwiftPM compiles it and does not re-verify it \
            once a checkout exists, and a build-tool plugin living there is EXECUTED during the \
            build. baseline records its hashes so eval can tell whether the dependency sources \
            that will be compiled are still the ones Package.resolved pins. Recording an empty \
            inventory because the walk could not run would leave that tree exempt from every \
            gate, which is the hole this closes.
            """
        }
    }
}

public enum BaselineRunner {
    /// SHA-256 of a file's exact bytes, lowercase hex.
    ///
    /// A MISSING FILE THROWS. It used to hash as empty data, on the theory
    /// that "this file doesn't exist" is itself part of what gets pinned --
    /// and that theory is exactly how this project shipped a defect that
    /// bricked every repository with external dependencies. The hash of zero
    /// bytes (`e3b0c442...`) is a perfectly well-formed SHA-256; written into
    /// `baseline.json` it is indistinguishable from a real pin, so a
    /// repository with source-control dependencies and no lockfile recorded
    /// "no dependencies at all" and reported success. Missing and empty are
    /// different states; they now have different outcomes, and the caller
    /// decides what a missing file means rather than being handed a
    /// plausible-looking wrong answer.
    ///
    /// The one caller that legitimately has to cope with absence is the
    /// lockfile pin (see `resolveLockfilePin`), which records
    /// `Lockfile.absentPin` -- a value no hash can ever equal -- and only
    /// after SwiftPM itself has confirmed the package produces no lockfile.
    static func sha256File(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BaselineError.missingFileForHash(url.path)
        }
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// EVERY manifest-or-manifest-equivalent file under `repo`, as a relative
    /// path -> SHA-256 map. `baseline` records this; gate 2a compares against
    /// it. See `BaselineRecord.manifestSHA256` for why it exists.
    ///
    /// "Manifest" is `ScopeGate.isManifestPath` and nothing else. Reusing that
    /// one predicate is the point: an inventory built from its own private
    /// idea of what a manifest is would drift from the scope gate the first
    /// time either changed, and the gap between the two would be a bypass
    /// nobody was looking at.
    ///
    /// SCANNED FROM DISK, not from `git ls-tree`. This is what makes the
    /// APPEARANCE check work without false positives. A manifest-equivalent
    /// file that is present but GITIGNORED -- an Xcode-written `.swiftpm/`,
    /// say -- is invisible to git, so a git-derived inventory would not record
    /// it and the first `eval` would report it as newly appeared on a
    /// repository where nothing had changed. Disk sees exactly what `swift
    /// build` sees, which is the surface that actually matters. `baseline` has
    /// already verified the tree is clean by the time this runs, so disk and
    /// `frozenCommit` agree on everything git can see.
    ///
    /// `.git` and `.build` are skipped. `.build` is not optional politeness:
    /// it holds every dependency's checkout, each with its own
    /// `Package.swift`, so scanning it would inventory hundreds of files that
    /// SwiftPM rewrites at will and turn every eval into a rejection.
    static func manifestInventory(repo: URL) throws -> [String: String] {
        let root = repo.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else {
            throw BaselineError.manifestInventoryFailed("could not enumerate \(root.path)")
        }

        var inventory: [String: String] = [:]
        for case let item as URL in walker {
            let name = item.lastPathComponent
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, name == ".git" || name == ".build" {
                walker.skipDescendants()
                continue
            }
            guard !isDirectory else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(root.path + "/") else { continue }
            let relative = String(full.dropFirst(root.path.count + 1))
            guard ScopeGate.isManifestPath(relative) else { continue }
            inventory[relative] = try sha256File(item)
        }
        return inventory
    }

    // =====================================================================
    // MARK: - The out-of-scope tree inventory
    // =====================================================================

    /// The paths `autor3search-swift` itself writes into the repository under
    /// test and tells `init` to gitignore. They are the harness's own output,
    /// not the agent's work, so they are excluded from the on-disk inventory
    /// (their bytes change on every eval by design) and they are the ONLY
    /// present-but-ignored paths `eval`'s dirty-tree gate tolerates.
    ///
    /// This is an ALLOWLIST, spelled out here once and consumed by both
    /// `treeInventory` and `EvalRunner`'s gate 2b, and it deliberately
    /// duplicates nothing from `.gitignore`: the ignore file is written by
    /// `init` into the repository, which means the agent can edit it. An
    /// allowlist derived from `.gitignore` would let the agent extend its own
    /// exemptions, which is precisely the bypass being closed.
    static let harnessOutputFiles: [String] = ["results.tsv", "run.log"]

    /// As `harnessOutputFiles`, for the two directories. Matched as "this
    /// directory and everything under it".
    static let harnessOutputDirectories: [String] = [".build", ".autor3search/profiles"]

    /// Directories never walked, and never inventoried: git's own object
    /// store, and SwiftPM's build directory.
    ///
    /// `.build` is not politeness. It holds every dependency's checkout and
    /// every intermediate SwiftPM rewrites at will, so inventorying it would
    /// turn every eval into a rejection -- and hashing a warm build directory
    /// is hundreds of megabytes of I/O per eval.
    static let neverWalkedDirectories: Set<String> = [".git", ".build"]

    /// Whether `relative` is one of the harness's own outputs.
    ///
    /// CASE-SENSITIVE, on every platform, and that is the safe direction on a
    /// case-insensitive filesystem. macOS's default APFS is
    /// case-insensitive-but-PRESERVING, so the enumerator always reports the
    /// real on-disk spelling: if `.build` already exists, a write to `.BUILD/x`
    /// lands in it and comes back spelled `.build/x`, which matches. What a
    /// case-INSENSITIVE comparison would add is the ability to create a
    /// genuinely new directory whose name differs from an allowlisted one only
    /// by case and have it silently exempted -- an over-match, in a check whose
    /// every over-match is a hole. Under-matching only ever produces a loud
    /// refusal naming the path.
    ///
    /// A trailing slash is tolerated because `git status --ignored` collapses a
    /// wholly-ignored directory into a single `dir/` record.
    ///
    /// `.build` AND `.git` ARE MATCHED AT ANY DEPTH, and that is a correction
    /// rather than a widening. `neverWalkedDirectories` has always been
    /// applied by NAME to every directory the disk walks hit -- see
    /// `treeInventory`, which tests `neverWalkedDirectories.contains(name)`
    /// against `lastPathComponent`, and `manifestInventory`, which tests
    /// `name == ".git" || name == ".build"` the same way. So gates 2a and 2c
    /// already stepped over a nested package's `Benchmarks/.build` at any
    /// depth, while THIS predicate -- which decides what gate 2b's ignored
    /// inventory records -- matched only at the repository root. A nested
    /// benchmark package's `.build` was therefore about to be hashed in full
    /// by `ignoredInventory` (hundreds of megabytes) and then reported as
    /// changed on the very next eval, because a build directory changes every
    /// time anything is built. Making the two agree is what gives the nested
    /// `.build` the same treatment the root's has always had; it opens no
    /// door, because the tree it now exempts here is one the other two
    /// inventories were already not looking at.
    ///
    /// `results.tsv`, `run.log` and `.autor3search/profiles/` stay ROOT-
    /// relative, deliberately: those are paths this tool writes, at exactly
    /// one place each, and a `Benchmarks/results.tsv` is not one of them.
    static func isHarnessOutput(_ relative: String) -> Bool {
        var path = relative
        while path.hasSuffix("/") { path.removeLast() }
        if harnessOutputFiles.contains(path) { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains(where: { neverWalkedDirectories.contains($0) }) { return true }
        return harnessOutputDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// What `treeInventory` records for one directory entry.
    ///
    /// Only a REGULAR file is hashed. A symbolic link records its destination
    /// instead of the bytes it points at, and anything else (a fifo, a socket,
    /// a device node) records its type. Two reasons, both load-bearing:
    ///
    /// - Reading THROUGH a link would let the recorded value describe a file
    ///   outside the repository, so swapping the link's target would change
    ///   what is compiled without changing the recorded value. Recording the
    ///   destination makes the swap itself the change.
    /// - `Data(contentsOf:)` on a fifo blocks forever. An unattended overnight
    ///   harness that can be hung by `mkfifo` is a denial of service with a
    ///   one-line setup.
    static func treeEntryDigest(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw BaselineError.missingFileForHash(url.path)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return try sha256File(url)
        case S_IFLNK:
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                ?? "<unreadable>"
            return "symlink:" + destination
        default:
            return "special:\(info.st_mode & S_IFMT)"
        }
    }

    /// EVERY file in the repository that `scope` does NOT cover, as a relative
    /// path -> digest map. `baseline` records this; `eval`'s gate 2c walks the
    /// disk again and compares.
    ///
    /// THE HOLE THIS CLOSES. Gate 1 enforces `scope` purely through GIT's path
    /// accounting -- `git diff --name-only frozenCommit HEAD` -- and the agent
    /// owns git's view of its own repository:
    ///
    ///     git update-index --assume-unchanged Benchmarks/Bench/Bench.swift
    ///     <edit it: repeatCount 1750 -> 1>
    ///     <commit an innocent in-scope source change>
    ///
    /// git then reports neither a changed path (gate 1 sees only the in-scope
    /// file) nor a dirty tree (gate 2b sees nothing), while `swift build`
    /// compiles the edited helper. Measured against the demo package, that one
    /// edit produced `eval rc=0, ratio 0.000742`. The project's own README
    /// claimed "`scope` closes the benchmark-helper hole"; it did not, because
    /// `scope` was only ever enforced against paths git chose to report.
    ///
    /// The existing manifest inventory closes the same door for MANIFESTS
    /// only. This is the general form: anything outside `scope` is compared by
    /// its bytes on disk, which no index flag, ignore rule or `.git/info/exclude`
    /// can talk out of noticing.
    ///
    /// It also closes the CASE-VARIANT MANIFEST. `ScopeGate.isManifestPath`
    /// matches case-sensitively -- correct for git-reported paths, and
    /// deliberately so -- but APFS is case-insensitive, so a file committed as
    /// `PACKAGE@SWIFT-6.4.SWIFT` is opened by SwiftPM when it looks for
    /// `Package@swift-6.4.swift`. `isManifestPath` does not match that
    /// spelling, so the manifest inventory never records it; this inventory
    /// does not care what it is called, and reports it as an EXTRA file.
    ///
    /// EXCLUSIONS, and why each is safe:
    ///
    /// - `.git/` and `.build/` (`neverWalkedDirectories`): git's own store,
    ///   and SwiftPM's, neither of which is source.
    /// - `results.tsv`, `run.log`, `.autor3search/profiles/`: the harness's own
    ///   output, which changes on every eval by design.
    /// - Anything `scope` matches: in-scope content is what the agent is
    ///   *supposed* to change. Gate 1 judges those by path and gate 2b requires
    ///   them to be committed.
    ///
    /// SCOPE MATCHING IS CASE-SENSITIVE, via `ScopeGate.matches`, the same one
    /// predicate gate 1 uses -- so "in scope" has exactly one definition here.
    /// On a case-insensitive filesystem that is again the safe direction: the
    /// enumerator reports the real on-disk spelling, so a path that folds onto
    /// an existing in-scope directory arrives already spelled the in-scope way,
    /// while a genuinely new `SOURCES/` next to no `Sources/` fails to match
    /// and is inventoried rather than exempted.
    ///
    /// Path comparison between the recorded map and the live one is ordinary
    /// Swift `String` equality, which compares by canonical equivalence -- an
    /// NFC and an NFD spelling of the same filename are the same key. That is
    /// the behaviour `ScopeGate` and `FrozenSnapshot.manifest` already rely on;
    /// canonical equivalence never folds two DIFFERENT filenames together, so
    /// it cannot over-match.
    static func treeInventory(repo: URL, scope: [String]) throws -> [String: String] {
        let root = repo.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else {
            throw BaselineError.treeInventoryFailed("could not enumerate \(root.path)")
        }

        var inventory: [String: String] = [:]
        for case let item as URL in walker {
            let name = item.lastPathComponent
            // `.isDirectoryKey` follows links, so a SYMLINK to a directory
            // would report true and be skipped silently. lstat first.
            var info = stat()
            let statted = lstat(item.path, &info) == 0
            let isRealDirectory = statted && (info.st_mode & S_IFMT) == S_IFDIR
            if isRealDirectory, neverWalkedDirectories.contains(name) {
                walker.skipDescendants()
                continue
            }
            guard !isRealDirectory else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(root.path + "/") else { continue }
            let relative = String(full.dropFirst(root.path.count + 1))
            guard !isHarnessOutput(relative) else { continue }
            guard !scope.contains(where: { ScopeGate.matches(relative, glob: $0) }) else { continue }
            inventory[relative] = try treeEntryDigest(item)
        }
        return inventory
    }

    // =====================================================================
    // MARK: - The dependency checkout inventory
    // =====================================================================

    /// Where SwiftPM puts each dependency's source: one git checkout per
    /// dependency, at the revision `Package.resolved` pins.
    static let checkoutsSubpath = ".build/checkouts"

    /// Every file SwiftPM will COMPILE out of `<directory>/.build/checkouts`,
    /// as a path relative to that directory (`benchmark/Sources/...`) ->
    /// digest. Each checkout's own `.git` is skipped: it is not compiled, it
    /// is a third of the tree, and git rewrites it.
    ///
    /// THE BLANKET EXEMPTION WAS THE BUG. `.build/` is excluded from the
    /// out-of-scope inventory (`neverWalkedDirectories`) and from the
    /// dirty-tree gate (`isHarnessOutput`), and git collapses the whole thing
    /// to a single `!!` record. But `.build/checkouts` is not build output --
    /// it is SOURCE, it is INSIDE the repository under test, and SwiftPM does
    /// not restore or re-verify it once the checkout exists. One `sed` in the
    /// agent's own tree:
    ///
    ///     .build/checkouts/benchmark/Sources/Benchmark/BenchmarkExecutor.swift
    ///     -    add(Int(nanoSeconds))
    ///     +    add(Int(nanoSeconds) / 100)
    ///
    /// plus a commit whose entire diff is `+// comment only`, measured
    /// `rc 0, verdict keep, ratio 0.0099977, warnings []`. Worse, the
    /// benchmark package's `BenchmarkPlugin` lives in that same unhashed tree
    /// and is a BUILD-TOOL PLUGIN: editing it is arbitrary code execution
    /// during gate 5, after gates 2a, 2b and 2c have all passed.
    ///
    /// WHY HASHING BEATS ASKING GIT, on both soundness and cost. Each checkout
    /// is a git repository at a pinned revision, so the obvious check is
    /// `rev-parse HEAD` against `Package.resolved` plus "is it clean". That is
    /// the same mistake a third time: "is it clean" comes out of git's index,
    /// and `git update-index --skip-worktree` inside the checkout defeats it,
    /// as does a `.git/info/exclude` entry for a planted file. It is also
    /// SLOWER -- one `git` process per dependency (eight for this project's
    /// demo package, ~12 ms each) against ~10 ms to hash the whole tree, which
    /// measured 7.7 MB across 803 files with `.git` excluded. Hashing asks the
    /// question SwiftPM's compiler actually answers: what bytes are on disk.
    ///
    /// The pin itself is already protected: `Package.resolved` is hashed by
    /// gate 2a, and git's content addressing means a checkout that IS at the
    /// pinned revision has the real bytes. So a checkout that is missing
    /// entirely is safe to allow -- SwiftPM re-clones it from that pin.
    ///
    /// `packagePath` selects WHICH package's checkouts. A nested benchmark
    /// package has its own `.build/checkouts`, holding its own copy of
    /// `ordo-one/package-benchmark` -- including `BenchmarkPlugin`, the
    /// build-tool plugin that is EXECUTED when the benchmark is built. That
    /// tree is compiled into the measured binary just as surely as the root
    /// package's is, so it gets its own inventory rather than being folded in
    /// with the root's: `checkoutDependency(of:)` groups by the first path
    /// component, and prefixing nested entries to share one map would make
    /// `Benchmarks` look like a dependency name.
    static func checkoutInventory(in directory: URL, packagePath: String? = nil) throws -> [String: String] {
        let packageRoot = BenchmarkPackage.directory(in: directory, path: packagePath)
        let root = packageRoot.appendingPathComponent(checkoutsSubpath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [:] }
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: []
        ) else {
            throw BaselineError.checkoutInventoryFailed("could not enumerate \(root.path)")
        }

        var inventory: [String: String] = [:]
        for case let item as URL in walker {
            var info = stat()
            guard lstat(item.path, &info) == 0 else { continue }
            let isRealDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            if isRealDirectory, item.lastPathComponent == ".git" {
                walker.skipDescendants()
                continue
            }
            guard !isRealDirectory else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(root.path + "/") else { continue }
            inventory[String(full.dropFirst(root.path.count + 1))] = try treeEntryDigest(item)
        }
        return inventory
    }

    /// The top-level dependency directory a checkout-relative path belongs to
    /// (`benchmark/Sources/X.swift` -> `benchmark`), or `nil` for a stray file
    /// sitting directly in `.build/checkouts`.
    ///
    /// Grouping by this is what lets a WHOLE missing dependency be tolerated
    /// (SwiftPM re-clones it from the pinned, hashed lockfile) while a
    /// partially-altered one -- a file edited, added or deleted inside a
    /// checkout that IS present -- is refused. SwiftPM will not repair the
    /// second case, and it is the one that changes what gets compiled.
    static func checkoutDependency(of path: String) -> String? {
        let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard first.count == 2, !first[0].isEmpty else { return nil }
        return String(first[0])
    }

    /// Every file that an ignore rule is hiding from `git status`, as a
    /// relative path -> digest map. `baseline` records it; gate 2b walks the
    /// same set again and refuses on any ADDED, MODIFIED or REMOVED entry.
    ///
    /// RECORD, DO NOT REFUSE, and the distinction is what makes this usable.
    /// The first version of this gate refused ANY present-but-ignored path
    /// outside a four-entry allowlist. That is correct about the attack and
    /// wrong about the world: `autor3search-swift`'s own repository ignores
    /// `docs/` and `.superpowers/` and has both on disk, so `eval` refused on
    /// the tool's own source tree -- and so would it on most real
    /// repositories, which ignore `.DS_Store`, editor state, vendored
    /// directories or pre-existing generated sources that genuinely exist.
    ///
    /// The reasoning that makes recording SAFE: an ignored file already
    /// present when the baseline was taken is part of the honest starting
    /// point. `frozenCommit` was taken with it there, the pinned measurement
    /// worktree's first build saw the same repository, and it confers no
    /// advantage to either side. What the attack requires is an ignored file
    /// that APPEARS or CHANGES after the freeze -- because the pinned worktree
    /// is a checkout of a COMMIT and can never contain it, so it exists on the
    /// candidate side only and manufactures a win on every later eval. That is
    /// exactly the set this map makes visible, and nothing else.
    ///
    /// REMOVAL counts too: deleting an ignored file the baseline build
    /// compiled changes what is compiled just as much as adding one.
    ///
    /// The ignored SET comes from git (`status --porcelain --ignored`), which
    /// is the only thing that knows the ignore rules -- they can live in any
    /// `.gitignore`, in `.git/info/exclude`, in a global excludes file or in
    /// `core.excludesFile`. The CONTENTS come from disk. git's traditional
    /// ignore mode collapses a wholly-ignored directory into one `dir/`
    /// record, so each such record is expanded here into its files; that
    /// collapse is also why `.build/` costs one `stat` rather than a walk of
    /// several thousand object files.
    ///
    /// The harness's own outputs are excluded (`isHarnessOutput`): `.build/`,
    /// `results.tsv`, `run.log` and `.autor3search/profiles/` change on every
    /// eval by design, and hashing a warm `.build` would be hundreds of
    /// megabytes of I/O per experiment.
    static func ignoredInventory(repo: URL, git: Git) throws -> [String: String] {
        var inventory: [String: String] = [:]
        for entry in try git.status(includingIgnored: true) where entry.isIgnored {
            guard !isHarnessOutput(entry.path) else { continue }
            var relative = entry.path
            let wasCollapsedDirectory = relative.hasSuffix("/")
            while relative.hasSuffix("/") { relative.removeLast() }
            guard !relative.isEmpty else { continue }
            let url = repo.appendingPathComponent(relative)

            // A collapsed directory record is expanded; anything else is one
            // entry. `lstat` rather than `isDirectory`, so a SYMLINK to a
            // directory is recorded as a link and never walked through.
            var info = stat()
            let statted = lstat(url.path, &info) == 0
            let isRealDirectory = statted && (info.st_mode & S_IFMT) == S_IFDIR
            guard wasCollapsedDirectory || isRealDirectory else {
                inventory[relative] = try treeEntryDigest(url)
                continue
            }
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil, options: []
            ) else {
                throw BaselineError.ignoredInventoryFailed("could not enumerate \(url.path)")
            }
            for case let item as URL in walker {
                var itemInfo = stat()
                guard lstat(item.path, &itemInfo) == 0 else { continue }
                if (itemInfo.st_mode & S_IFMT) == S_IFDIR { continue }
                let full = item.standardizedFileURL.path
                let root = repo.standardizedFileURL.path
                guard full.hasPrefix(root + "/") else { continue }
                let itemRelative = String(full.dropFirst(root.count + 1))
                guard !isHarnessOutput(itemRelative) else { continue }
                inventory[itemRelative] = try treeEntryDigest(item)
            }
        }
        return inventory
    }

    /// What goes into `BaselineRecord.packageResolvedSHA256`: either the
    /// lockfile's real hash, or `Lockfile.absentPin` -- never the hash of
    /// nothing, and never a pin established without checking.
    ///
    /// Four states, three of them refusals:
    ///
    /// 1. A lockfile exists and git tracks it -> pin its real bytes. (The
    ///    dirty-tree guard at the top of `run` already guarantees a tracked
    ///    file on disk matches what is committed at `frozenCommit`.)
    /// 2. A lockfile exists and git does NOT track it -> `lockfileNotTracked`.
    ///    A clean tree plus an untracked file means an ignore rule is hiding
    ///    it; see that case's own reasoning.
    /// 3. No lockfile, and SwiftPM produces none -> `Lockfile.absentPin`. THE
    ///    EDGE CASE THAT MUST KEEP WORKING: a package with no external
    ///    dependencies legitimately has no lockfile and never will, and
    ///    refusing here would be a worse bug than the one this fixes.
    /// 4. No lockfile, but SwiftPM produces one -> `unpinnedDependencies`.
    ///
    /// The 3-vs-4 split is decided by ASKING SWIFTPM, not by reading the
    /// manifest. `swift package describe`'s top-level `dependencies` array
    /// reports only DIRECT dependencies, and a `fileSystem` (path) dependency
    /// whose own manifest declares a `sourceControl` one makes the root
    /// package produce a `Package.resolved` while describe shows nothing but
    /// `fileSystem` -- verified live, and the reason a manifest-only test
    /// would silently under-report. `Lockfile.probe` runs `swift package
    /// resolve` and reads what appears on disk, which cannot be fooled that
    /// way.
    ///
    /// The probe runs in the PINNED WORKTREE, never in `repo`: it writes
    /// `Package.resolved` and `.build/`, and `repo`'s cleanliness is what
    /// every later gate depends on. The worktree is disposable and is reset
    /// to `frozenCommit` at the end of `run` anyway.
    private static func resolveLockfilePin(repo: URL, worktree: URL) throws -> String {
        if Lockfile.exists(in: repo) {
            guard Lockfile.isTracked(repo: repo) != false else {
                throw BaselineError.lockfileNotTracked
            }
            return try sha256File(Lockfile.url(in: repo))
        }
        switch Lockfile.probe(in: worktree) {
        case .notProduced:
            return Lockfile.absentPin
        case .required:
            throw BaselineError.unpinnedDependencies(
                identities: (try? Lockfile.externalDependencyIdentities(repo: repo)) ?? [])
        case .undetermined(let why):
            throw BaselineError.dependencyPinUndetermined(why)
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }

    /// Runs `swift build -c release --product <name>` in the pinned
    /// worktree for the benchmark target (when known) and for
    /// `BenchmarkTool` itself, so the first `eval` reuses a warm `.build`
    /// instead of paying a cold Swift build. Best-effort: a build that
    /// cannot succeed does not block `baseline` from completing -- `eval`'s
    /// own build gate (Task 17) is where a repository that cannot build
    /// becomes a real, scored refusal, on its own merits, regardless of
    /// what `baseline` decides here.
    private static func warmBuild(worktree: URL, benchmarkTarget: String?) -> [String] {
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        var products = ["BenchmarkTool"]
        if let benchmarkTarget { products.insert(benchmarkTarget, at: 0) }

        var warnings: [String] = []
        for product in products {
            do {
                let result = try Subprocess.run(
                    swift, ["build", "-c", "release", "--product", product],
                    cwd: worktree, env: SanitizedEnvironment.forTools(), timeout: 1800)
                guard result.exitCode == 0 else {
                    warnings.append("""
                        warm build of product \(product) failed (exit \(result.exitCode)); the \
                        first eval will pay a cold Swift build instead of reusing a warm cache. \
                        \(result.stderr.suffix(2000))
                        """)
                    continue
                }
            } catch {
                warnings.append("warm build of product \(product) could not run: \(error)")
            }
        }
        return warnings
    }

    /// Whether `url` is a registered git worktree checkout -- `git worktree
    /// add` marks one by writing a `.git` FILE there (not a directory)
    /// containing `gitdir: <path>`. Used to decide, when the pinned
    /// worktree path is not currently verified, whether it is safe to
    /// `repoint` (a registered worktree, just stale or dirty) or whether it
    /// must be cleared and re-added from scratch (nothing registered there
    /// at all, or a corrupt leftover).
    private static func isRegisteredWorktree(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Gets the pinned worktree to exactly `commit`, clean, reusing an
    /// existing registration wherever possible instead of insisting on a
    /// fresh `git worktree add`.
    ///
    /// `git worktree add` refuses outright if the target path already
    /// exists -- so on a retry of an interrupted `baseline` (the worktree
    /// was already added, then a warm build or a later step failed or was
    /// killed), unconditionally calling `add` again would die with `fatal:
    /// '<path>' already exists`, permanently stuck until an operator
    /// manually deletes the run directory. That defeats the "always
    /// retryable with the same tag" property the rest of `run` is designed
    /// around. `Worktree.repoint` (`checkout --force` + `clean -fd`) is the
    /// idempotent way back to a clean checkout at `commit` for anything
    /// already registered; only a stray, unregistered directory needs to be
    /// cleared and re-added.
    private static func pinWorktree(git: Git, at url: URL, to commit: String) throws {
        guard (try? Worktree.verify(at: url, expectedCommit: commit)) != true else { return }
        if isRegisteredWorktree(at: url) {
            try Worktree.repoint(git: git, at: url, to: commit)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? Worktree.remove(git: git, at: url)
            try? FileManager.default.removeItem(at: url)
            try Worktree.add(git: git, at: url, commit: commit)
        } else {
            try Worktree.add(git: git, at: url, commit: commit)
        }
    }

    /// Freezes the success criteria and pins the measurement point.
    ///
    /// ORDERING (see the written report for the full reasoning): the dirty-
    /// tree check and the tag-reuse check happen before any side effect, so
    /// a refusal from either leaves nothing behind to clean up. HEAD is
    /// captured before touching the run branch at all, so an existing but
    /// stale branch (an interrupted earlier attempt, repository since moved
    /// on) is refused rather than silently frozen at the wrong commit.
    /// Everything after that -- branch, frozen snapshot, worktree, warm
    /// build -- is either idempotent (the branch and worktree steps check
    /// what already exists before creating anything) or explicitly
    /// non-fatal (a failing warm build only warns), so a `baseline`
    /// interrupted partway through (a killed process, a transient git
    /// failure) can always be retried with the SAME tag: reuse is gated on
    /// `baseline.json` existing, and that file is written last, atomically,
    /// only once every step before it has actually succeeded. The one hard
    /// failure that is NOT retried-past silently is `swift package
    /// describe` itself failing -- see `BaselineError.packageDescribeFailed`.
    @discardableResult
    public static func run(repo: URL, tag: String, env: [String: String]) throws -> BaselineRecord {
        let git = Git(repo: repo)
        guard try git.isClean() else { throw BaselineError.dirtyTree }

        let home = try StateHome(repo: repo, env: env)
        let recordURL = try home.baselineRecordURL(tag: tag)
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw BaselineError.tagInUse(tag)
        }

        // Hashed HERE, before the first side effect, not at the bottom next to
        // the lockfile pin.
        //
        // ROUND 2, raised as LOW 6. `sha256File` now THROWS on a missing file
        // (which is the whole point -- it used to answer "the hash of zero
        // bytes" and that is how the dependency pin came to pin nothing). But
        // in round 1 these two calls still sat at the bottom of `run`, so a
        // repository with no `.autor3search/config.yaml` -- `baseline` run
        // before `init`, the ordinary mistake -- now failed AFTER the run
        // branch had been created, the frozen snapshot written and the
        // worktree pinned, leaving all of it behind for an error that was
        // knowable from the start. Reading them up here restores the ordering
        // guarantee this function's own doc comment claims: every refusal that
        // can happen leaves nothing to clean up.
        //
        // It also closes a TOCTOU window. Recording a hash taken at the end
        // would pin whatever the file became during the warm build; these are
        // the bytes as they were when the tree was verified clean.
        let configURL = repo.appendingPathComponent(".autor3search/config.yaml")
        let configSHA256 = try sha256File(configURL)
        let packageSwiftSHA256 = try sha256File(repo.appendingPathComponent("Package.swift"))
        // Loaded ONCE, here, and reused for `scope`, for the benchmark
        // package's location and for the warm build. It used to be re-read
        // twice with `try?` at two different points in `run`, which was
        // harmless while the only thing read was `scope` and is not once the
        // geometry of what gets built depends on it: two reads are two chances
        // to disagree about which package the benchmark target lives in.
        //
        // Still `try?`. A config that cannot be parsed yields an empty scope
        // (the fail-closed direction: the whole tree is inventoried) and a nil
        // benchmark package path (the root, which is where `describe` would
        // look anyway). `eval` rejects an unparseable config outright with
        // `config_unreadable`, so the run cannot proceed on one either way,
        // and turning a config typo into a `baseline` crash about inventories
        // would be the less useful diagnosis.
        let liveConfig = try? Config.load(configURL)
        // The nested benchmark package's location is validated BEFORE the
        // first side effect, alongside the hashes: a `benchmark_package_path`
        // that escapes the repository, or that names a directory holding no
        // Package.swift, is knowable from the start, and every refusal above
        // this line leaves nothing behind to clean up.
        try liveConfig?.validateBenchmarkPackage(in: repo)
        let benchmarkPackagePath = liveConfig?.benchmarkPackagePath
        let benchmarkPackageURL = BenchmarkPackage.directory(in: repo, path: benchmarkPackagePath)
        // The manifest inventory belongs here for the same two reasons: a
        // failure leaves nothing behind, and the hashes are the bytes from the
        // moment the tree was verified clean rather than whatever the warm
        // build left lying around.
        let manifestSHA256 = try manifestInventory(repo: repo)
        // ...and the general form of the same idea: every file OUTSIDE
        // `scope`, hashed from disk. See `treeInventory`.
        //
        // `scope` is read from the live config here because that config's own
        // bytes are pinned by `configSHA256` two lines above, and `eval`
        // verifies that hash (gate 2) BEFORE it uses `scope` for this
        // comparison (gate 2c). So the scope this inventory is taken at and
        // the scope it is checked at are provably the same list.
        //
        // A config that cannot be parsed yields an EMPTY scope, which
        // inventories the whole tree -- the fail-closed direction. `baseline`
        // does not refuse here on that account: `eval` rejects an unparseable
        // config outright (`config_unreadable`), so the run cannot proceed on
        // one either way, and turning a config typo into a `baseline` crash
        // with a message about inventories would be the less useful diagnosis.
        let scope = liveConfig?.scope ?? []
        let treeSHA256 = try treeInventory(repo: repo, scope: scope)
        // ...and the files an ignore rule hides from git entirely. RECORDED,
        // not refused: see `ignoredInventory`. Taken here, with the other two,
        // while the tree is verified clean and before `swift package describe`
        // creates `.build` -- which is excluded anyway, but taking all three
        // hashes at one instant is what makes them describe one state.
        let ignoredSHA256 = try ignoredInventory(repo: repo, git: git)

        // Captured BEFORE touching the branch: creating or checking out the
        // run branch must never change which commit gets frozen.
        let commit = try git.head()
        let branch = "autor3search-swift/\(tag)"
        if git.branchExists(branch) {
            let branchCommit = try git.run(["rev-parse", branch])
            guard branchCommit == commit else {
                throw BaselineError.staleRunBranch(
                    tag: tag, branchCommit: branchCommit, headCommit: commit)
            }
            try git.run(["checkout", "-q", branch])
        } else {
            try git.createBranch(branch)
        }

        // Freeze tests AND benchmarks exactly once, here -- never again for
        // this run. A later re-snapshot would let an agent that renamed a
        // test directory slip out of the freeze silently.
        //
        // A `swift package describe` that cannot run at all is fatal, not a
        // warning -- see `BaselineError.packageDescribeFailed`. The empty-
        // manifest check below is unconditional for the same reason: there
        // is no path left where an empty freeze set is tolerated silently.
        //
        // TWO DESCRIBES, TWO DIFFERENT QUESTIONS, and they must not be
        // conflated. The ROOT package's describe answers "which TEST targets
        // are the correctness contract, and which source targets exist" --
        // gate 6 runs `swift test` at the repository root and nowhere else,
        // because the library's tests live there. The BENCHMARK PACKAGE's
        // describe answers "which BENCHMARK targets are measured", and in the
        // nested layout that is a different package with a different manifest.
        // In the root-package layout the two are the same directory and the
        // second describe is skipped entirely, so nothing changes.
        let description: PackageDescription
        do {
            description = try PackageDescribe.describe(repo: repo)
        } catch {
            throw BaselineError.packageDescribeFailed("\(error)")
        }
        // THE FREEZE SET IS THE UNION. An agent that can rewrite the benchmark
        // can make it measure less work, which is the whole reason benchmark
        // sources are frozen alongside the tests -- and a benchmark target
        // living in a nested package is no less rewritable for being nested.
        // Its paths come back relative to ITS package (`Benchmarks/<Target>`
        // for a describe run in `Benchmarks/`), so they are re-rooted exactly
        // once, here, through `BenchmarkPackage.repoRelative`; everything
        // downstream -- `FrozenSnapshot.directories`, gate 3's restore, gate
        // 4's new-file scan -- is repo-relative and stays that way.
        var dirs = description.frozenDirectories
        if let benchmarkPackagePath, !benchmarkPackagePath.isEmpty {
            let benchmarkDescription: PackageDescription
            do {
                benchmarkDescription = try PackageDescribe.describe(repo: benchmarkPackageURL)
            } catch {
                throw BaselineError.packageDescribeFailed(
                    "in the nested benchmark package at \(benchmarkPackagePath)/: \(error)")
            }
            // Its TEST targets are frozen too. A nested benchmark package
            // rarely has any, but if it does they are as much a thing an agent
            // could weaken as the root package's, and `frozenDirectories` is
            // already defined as "tests AND benchmarks".
            dirs += benchmarkDescription.frozenDirectories.map {
                BenchmarkPackage.repoRelative($0, under: benchmarkPackagePath)
            }
            dirs = Array(Set(dirs)).sorted()
        }
        for dir in dirs {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: repo.appendingPathComponent(dir).path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw BaselineError.missingFrozenDirectory(dir)
            }
        }
        let frozenStore = try home.frozenDir(tag: tag)
        let snapshot = try FrozenSnapshot.snapshot(repo: repo, directories: dirs, into: frozenStore)
        guard !snapshot.manifest.isEmpty else { throw BaselineError.emptyFreezeManifest }
        // R4: the persisted manifest lives at `<run>/frozen-manifest.json`,
        // a sibling of `frozen/` (the file-copy store) and `baseline.json`
        // -- the path Task 17 was told to load.
        try snapshot.save(to: try home.runDir(tag: tag).appendingPathComponent("frozen-manifest.json"))

        // Pin the worktree, reusing an existing registration if one is
        // already there (see `pinWorktree`'s doc comment for why a plain
        // `Worktree.add` is not safe to call unconditionally).
        let worktreeURL = try home.worktreeURL(tag: tag)
        try pinWorktree(git: git, at: worktreeURL, to: commit)

        // THE DEPENDENCY PIN, decided before anything expensive happens and
        // before `baseline.json` is written. Runs here rather than alongside
        // the other two hashes at the bottom because it needs the pinned
        // worktree to probe in -- see `resolveLockfilePin`. A refusal at this
        // point leaves only idempotent, retryable side effects behind (the
        // branch, the frozen snapshot, the worktree), exactly like every other
        // refusal after the two pre-side-effect guards.
        let packageResolvedPin = try resolveLockfilePin(repo: repo, worktree: worktreeURL)

        // Warm the release build so every eval after this one reuses it
        // instead of paying a cold Swift build. Best-effort: see
        // `warmBuild`'s doc comment for why a repository that cannot
        // currently build does not block baseline from completing.
        //
        // Warmed in the WORKTREE's copy of the benchmark package, not the
        // worktree root: `swift build --product BenchmarkTool` has to run
        // against the package that declares the dependency providing it, and
        // in the nested layout that is `<worktree>/<benchmark_package_path>`.
        // A warm build aimed at the root package would exit non-zero on every
        // nested-layout repository ("no product named BenchmarkTool") and
        // every eval would then pay a cold build it was told it would not.
        for message in warmBuild(
            worktree: BenchmarkPackage.directory(in: worktreeURL, path: benchmarkPackagePath),
            benchmarkTarget: liveConfig?.benchmarkTarget
        ) {
            warn(message)
        }

        // `swift build` can leave the worktree dirty with files SwiftPM
        // writes outside `.build` -- verified empirically: a package with a
        // source-control dependency gets a fresh, untracked
        // `Package.resolved`. `Worktree.verify` folds cleanliness into its
        // verdict (Task 17's worktree-integrity gate is a single `verify`
        // call that must fail closed), so leaving this dirty would make the
        // very first eval after a perfectly healthy baseline refuse.
        // `.build/` itself is already protected: `init` writes it into the
        // repository's TRACKED `.gitignore` before `baseline` can ever run
        // (a dirty tree is refused above), so it is committed at
        // `frozenCommit` and `clean -fd` already leaves it alone. Repoint to
        // the SAME commit -- a no-op checkout whose only job is to run
        // `clean -fd` and reset any tracked-file modification -- to restore
        // that cleanliness before this run's record is written.
        if (try? Worktree.isClean(at: worktreeURL)) != true {
            let buildDirExisted = FileManager.default.fileExists(
                atPath: worktreeURL.appendingPathComponent(".build").path)
            try Worktree.repoint(git: git, at: worktreeURL, to: commit)
            if buildDirExisted,
               !FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent(".build").path) {
                warn("""
                    the warm .build cache was deleted while restoring the pinned worktree to a \
                    clean state, because .gitignore (as committed at frozenCommit) does not \
                    cover .build/. init writes that entry automatically; if this repository's \
                    .gitignore was hand-edited afterward, restore it, or every eval will pay a \
                    cold Swift build.
                    """)
            } else {
                warn("""
                    the warmed release build left untracked or modified files in the pinned \
                    worktree; reset the worktree to frozenCommit to restore the cleanliness \
                    Task 17's worktree-integrity gate depends on. A fresh Package.resolved used \
                    to be the usual cause and no longer can be: a package that produces one now \
                    has to have it tracked before this point (see resolveLockfilePin), so \
                    anything left here is something else worth looking at.
                    """)
            }
        }

        // THE DEPENDENCY CHECKOUTS, recorded LAST because they are the one
        // inventory that cannot be taken before the side effects: nothing has
        // cloned them until SwiftPM has resolved. `swift package describe`
        // above is mandatory and fatal-on-failure, and it resolves the whole
        // graph into the REPOSITORY's `.build/checkouts`; the warm build does
        // the same in the worktree. Measured on the demo package: both sides
        // came back byte-identical, 803 files, same set -- which they must,
        // since both resolve the same pinned `Package.resolved`. The two are
        // merged into one map, and a disagreement between them is itself a
        // refusal: two checkouts of the same pinned revision differing means
        // one of them is not that revision.
        var checkoutSHA256 = try checkoutInventory(in: repo)
        for (path, digest) in try checkoutInventory(in: worktreeURL) {
            if let existing = checkoutSHA256[path], existing != digest {
                throw BaselineError.checkoutInventoryFailed("""
                    \(checkoutsSubpath)/\(path) differs between the repository and the pinned \
                    worktree, though both resolve the same \(Lockfile.name). One of the two is \
                    not the revision that file's dependency is pinned to
                    """)
            }
            checkoutSHA256[path] = digest
        }

        // THE NESTED BENCHMARK PACKAGE'S OWN CHECKOUTS, on both sides, by the
        // identical argument one paragraph up. It resolves its own
        // `Package.resolved` into its own `.build/checkouts`, that tree is
        // what the benchmark binary is compiled from, and `BenchmarkPlugin`
        // -- executed during that build -- lives in it. `.build` is exempt
        // from every other inventory at any depth, so without this the nested
        // dependency source would be the one part of the measured binary
        // nothing had hashed.
        //
        // `nil`, not `[:]`, when there is no nested package: the empty map has
        // to keep meaning "there is a nested package and it has no checkouts",
        // which is a state gate 2d treats differently from "there is no nested
        // package at all".
        var benchmarkCheckoutSHA256: [String: String]?
        if let benchmarkPackagePath, !benchmarkPackagePath.isEmpty {
            var merged = try checkoutInventory(in: repo, packagePath: benchmarkPackagePath)
            for (path, digest) in try checkoutInventory(
                in: worktreeURL, packagePath: benchmarkPackagePath) {
                if let existing = merged[path], existing != digest {
                    throw BaselineError.checkoutInventoryFailed("""
                        \(benchmarkPackagePath)/\(checkoutsSubpath)/\(path) differs between the \
                        repository and the pinned worktree, though both resolve the same \
                        \(benchmarkPackagePath)/\(Lockfile.name). One of the two is not the \
                        revision that file's dependency is pinned to
                        """)
                }
                merged[path] = digest
            }
            benchmarkCheckoutSHA256 = merged
        }

        let record = BaselineRecord(
            tag: tag,
            frozenCommit: commit,
            measurementCommit: commit,
            configSHA256: configSHA256,
            packageSwiftSHA256: packageSwiftSHA256,
            packageResolvedSHA256: packageResolvedPin,
            toolVersion: BuildInfo.version,
            manifestSHA256: manifestSHA256,
            treeSHA256: treeSHA256,
            ignoredSHA256: ignoredSHA256,
            checkoutSHA256: checkoutSHA256,
            benchmarkCheckoutSHA256: benchmarkCheckoutSHA256)
        try record.save(to: recordURL)
        return record
    }
}
