// Tests/AutoR3SearchKitTests/NestedBenchmarkPackageTests.swift
//
// The nested benchmark package: `benchmark_package_path`, and the gate parity
// that has to come with it.
//
// A nested package brings a SECOND `.build`, a SECOND `Package.resolved` and a
// SECOND `.build/checkouts` into the repository under test. Every one of those
// is a tree the measured binary is compiled from, and every gate that protects
// the root package's equivalent has to protect it too -- or this feature
// silently reopens vectors that took nine review passes to close. These tests
// are the binding: each one names the gate it holds and the bypass that gate
// exists to stop.
import Foundation
import Testing
@testable import AutoR3SearchKit

// =========================================================================
// MARK: - Backward compatibility, which is the thing most easily broken
// =========================================================================

/// The exact `config.yaml` body this project has written since before
/// `benchmark_package_path` existed, byte for byte.
///
/// Not "a config that looks like the old one" -- the old one. `baseline`
/// records a SHA-256 of these bytes and gate 2 refuses a mismatch, so this
/// literal is what an in-flight run's `configSHA256` was taken over.
private let legacyConfigYAML = """
version: 1
scope:
  - Sources/**
benchmark_target: Bench
benchmarks:
  - A
count: 10
alpha: 0.05
min_effect_pct: 1.0
max_regress_pct: 5.0
timeout_seconds: 600
"""

/// SHA-256 of `legacyConfigYAML` + a trailing newline, computed by this
/// project's own `BaselineRunner.sha256File` before `benchmark_package_path`
/// existed and pinned here as a literal.
///
/// The literal is the point. A test that hashes the file and compares it
/// against a hash of the same file proves nothing; this compares today's
/// bytes against a number recorded when the field did not exist, which is
/// exactly the comparison gate 2 makes on a repository mid-run.
private let legacyConfigSHA256 =
    "5a9072681a6503548132b9398149db7b7c24296bfdbd11d95c6b4aa1babdd0de"

@Test func aConfigWrittenBeforeBenchmarkPackagePathExistedStillLoads() throws {
    let config = try YAMLDecodedConfig(legacyConfigYAML)
    // The whole point: absent means the repository root, not a parse failure.
    #expect(config.benchmarkPackagePath == nil)
    #expect(!config.hasNestedBenchmarkPackage)
    // And every other value is exactly what it was.
    #expect(config.benchmarkTarget == "Bench")
    #expect(config.scope == ["Sources/**"])
    #expect(config.count == 10)
    #expect(config.purgeBuildOutput == false)
    try config.validate()
}

/// Gate 2 compares `configSHA256` against the bytes on disk. Adding a field to
/// the Swift type must not change those bytes for a repository that never
/// edits its config -- and nothing in `Config`'s decode path rewrites the
/// file, so this is really a test that the file is READ and not round-tripped.
@Test func aLegacyConfigFileHashesToWhatBaselineWouldHavePinned() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.yaml")
    try (legacyConfigYAML + "\n").write(to: url, atomically: true, encoding: .utf8)

    let before = try BaselineRunner.sha256File(url)
    // Loading must not touch the file.
    let config = try Config.load(url)
    let after = try BaselineRunner.sha256File(url)
    #expect(before == after)
    #expect(before == legacyConfigSHA256,
            "the legacy config's bytes hash to \(before); the pinned value is \(legacyConfigSHA256)")
    #expect(config.benchmarkPackagePath == nil)
}

/// ABSENT AND WRONG ARE DIFFERENT STATES. `decodeIfPresent(...) ?? nil`,
/// written out rather than reached through `try?`, is what keeps a malformed
/// value loud. A `try?` here would read `benchmark_package_path: [Benchmarks]`
/// as "the repository root" and measure the wrong package in silence.
@Test func aMalformedBenchmarkPackagePathThrowsRatherThanDefaulting() throws {
    let yaml = legacyConfigYAML + "\nbenchmark_package_path:\n  - Benchmarks\n"
    #expect(throws: (any Error).self) { _ = try YAMLDecodedConfig(yaml) }
}

@Test func aConfigWithTheKeyPresentDecodesIt() throws {
    let yaml = legacyConfigYAML + "\nbenchmark_package_path: Benchmarks\n"
    let config = try YAMLDecodedConfig(yaml)
    #expect(config.benchmarkPackagePath == "Benchmarks")
    #expect(config.hasNestedBenchmarkPackage)
}

/// `init` serialises the config it just built. For a root-package repository
/// the new key must not appear at all -- an emitted `benchmark_package_path:
/// null` would change the bytes (and therefore the hash) of every config this
/// tool writes, for a value that means what its absence already meant.
@Test func serialisingARootLayoutConfigEmitsNoBenchmarkPackagePathKey() throws {
    let config = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "Bench", benchmarks: ["A"])
    let yaml = try config.serialized()
    #expect(!yaml.contains("benchmark_package_path"),
            "a root-layout config serialised to:\n\(yaml)")
}

@Test func serialisingANestedLayoutConfigEmitsTheKeyAndItsComment() throws {
    let config = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "Bench", benchmarks: ["A"],
        benchmarkPackagePath: "Benchmarks")
    let yaml = InitRunner.annotated(try config.serialized())
    #expect(yaml.contains("benchmark_package_path: Benchmarks"))
    #expect(yaml.contains("# The directory of the SwiftPM package that declares benchmark_target"))
    // Round-trips.
    #expect(try YAMLDecodedConfig(yaml).benchmarkPackagePath == "Benchmarks")
}

// =========================================================================
// MARK: - The path is validated, not merely stored
// =========================================================================

/// The rules, and the reason each exists, are on `BenchmarkPackage.Invalid`.
/// What this binds is that every one of them REFUSES: a
/// `benchmark_package_path` that escapes the repository would have its
/// sources compiled into the measured binary while every inventory -- all of
/// which are taken relative to the repository root -- looked somewhere else.
@Test func benchmarkPackagePathMustBeRelativeAndStayInsideTheRepository() {
    for bad in ["/etc", "~/x", "..", "../sibling", "Benchmarks/../../escape", "a/../../b"] {
        #expect(throws: (any Error).self, "\(bad) was accepted") {
            try BenchmarkPackage.validateShape(bad)
        }
    }
    #expect(throws: (any Error).self) { try BenchmarkPackage.validateShape("") }
}

/// `.git` and `.build` are skipped by `treeInventory` and `manifestInventory`
/// at ANY depth, so a benchmark package under either would be compiled while
/// no disk inventory ever saw it.
@Test func benchmarkPackagePathMayNotHideUnderADirectoryNoInventoryWalks() {
    for bad in [".build", ".build/pkg", "x/.build/pkg", ".git", "x/.git/y"] {
        #expect(throws: (any Error).self, "\(bad) was accepted") {
            try BenchmarkPackage.validateShape(bad)
        }
    }
}

@Test func anOrdinaryNestedPathIsAccepted() throws {
    try BenchmarkPackage.validateShape("Benchmarks")
    try BenchmarkPackage.validateShape("dev/Benchmarks")
    try BenchmarkPackage.validateShape("Benchmarks-2")
}

/// The disk half: the directory has to be a real SwiftPM package. Checked
/// separately from the shape so `Config.validate()` stays pure.
@Test func benchmarkPackagePathMustContainAPackageManifest() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("Benchmarks"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(throws: (any Error).self) { try BenchmarkPackage.validate("Benchmarks", in: dir) }
    try "// swift-tools-version: 6.0\n".write(
        to: dir.appendingPathComponent("Benchmarks/Package.swift"),
        atomically: true, encoding: .utf8)
    try BenchmarkPackage.validate("Benchmarks", in: dir)

    // ...and the same judgement reached through the config, which is how
    // `eval`, `baseline` and `doctor` all ask.
    var config = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "B", benchmarks: ["A"],
        benchmarkPackagePath: "Benchmarks")
    try config.validateBenchmarkPackage(in: dir)
    config.benchmarkPackagePath = "NotThere"
    #expect(throws: (any Error).self) { try config.validateBenchmarkPackage(in: dir) }
}

/// `validate()` is pure -- no repository, no filesystem -- so it can only
/// check the shape. It must still check it: a config whose path escapes the
/// repository has to be refused even by a caller that has no repo to hand.
@Test func configValidateRejectsABadPathWithoutTouchingTheDisk() {
    var config = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "B", benchmarks: ["A"],
        benchmarkPackagePath: "../outside")
    #expect(throws: (any Error).self) { try config.validate() }
    config.benchmarkPackagePath = "Benchmarks"
    #expect(throws: Never.self) { try config.validate() }
}

// =========================================================================
// MARK: - Geometry
// =========================================================================

@Test func repoRelativeJoinsExactlyOnce() {
    #expect(BenchmarkPackage.repoRelative("Benchmarks/Bench", under: "Benchmarks")
        == "Benchmarks/Benchmarks/Bench")
    #expect(BenchmarkPackage.repoRelative("Tests/T", under: nil) == "Tests/T")
    #expect(BenchmarkPackage.repoRelative("Tests/T", under: "") == "Tests/T")
}

/// GATE 5 / THE MEASURED-BINARY SNAPSHOT. The binaries live under the
/// BENCHMARK PACKAGE's `.build/release/`, because that is the package
/// `swift build` was pointed at. A snapshot taken over the root's would hash
/// two files that do not exist; `digests(of:)` records nothing for an absent
/// file, so the per-sample guard would then be guarding an EMPTY set -- a
/// guard that passes because it is guarding nothing, which is worse than no
/// guard at all because it looks like one.
@Test func measuredBinariesFollowTheBenchmarkPackage() {
    let side = URL(fileURLWithPath: "/tmp/side")
    let root = EvalRunner.measuredBinaries(in: side, benchmarkTarget: "Bench")
    #expect(root.map(\.path) == ["/tmp/side/.build/release/Bench",
                                 "/tmp/side/.build/release/BenchmarkTool"])
    let nested = EvalRunner.measuredBinaries(
        in: side, benchmarkTarget: "Bench", packagePath: "Benchmarks")
    #expect(nested.map(\.path) == ["/tmp/side/Benchmarks/.build/release/Bench",
                                   "/tmp/side/Benchmarks/.build/release/BenchmarkTool"])
    // Four, both sides, and all four under the nested package.
    let both = EvalRunner.measuredBinaries(
        baselineWorktree: URL(fileURLWithPath: "/tmp/base"),
        candidateWorktree: URL(fileURLWithPath: "/tmp/cand"),
        benchmarkTarget: "Bench", packagePath: "Benchmarks")
    #expect(both.count == 4)
    #expect(both.allSatisfy { $0.path.contains("/Benchmarks/.build/release/") })
}

/// GATE 4b / GATE 6b. The purge has to reach the NESTED `.build/plugins`,
/// which is the one that actually executes: the benchmark is built from the
/// nested package, so its build-tool plugin is compiled and run there.
/// `buildRoots` is the seam every purge goes through, so a future gate gets
/// both roots by calling it rather than by remembering to.
@Test func buildRootsCoverBothPackagesOnEachSide() {
    let side = URL(fileURLWithPath: "/tmp/side")
    let rootLayout = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "B", benchmarks: ["A"])
    let rootRoots = rootLayout.buildRoots(in: side, sideDescription: "the candidate repository")
    #expect(rootRoots.count == 1)
    #expect(rootRoots[0].0.path == "/tmp/side")

    let nestedLayout = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "B", benchmarks: ["A"],
        benchmarkPackagePath: "Benchmarks")
    let nestedRoots = nestedLayout.buildRoots(in: side, sideDescription: "the candidate repository")
    #expect(nestedRoots.map(\.0.path) == ["/tmp/side", "/tmp/side/Benchmarks"])
    #expect(nestedRoots[1].1.contains("Benchmarks/"))
}

// =========================================================================
// MARK: - Gate 2b and 2c: the nested .build must be exempt, at any depth
// =========================================================================

/// `neverWalkedDirectories` was ALREADY a name match at any depth --
/// `treeInventory` tests `neverWalkedDirectories.contains(lastPathComponent)`
/// and `manifestInventory` tests `name == ".git" || name == ".build"` -- so
/// gate 2c was already right about a nested `.build`. Checked, not assumed:
/// the question the brief asked was "name match at any depth, or
/// root-relative?", and the answer decides whether gate 2c needed changing.
@Test func gate2cDoesNotWalkANestedPackagesBuildDirectory() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    for sub in ["Sources/Lib", "Benchmarks/.build/release", "Benchmarks/Benchmarks/Bench",
                "Benchmarks/.build/checkouts/benchmark/Sources"] {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try "lib".write(to: dir.appendingPathComponent("Sources/Lib/Lib.swift"),
                    atomically: true, encoding: .utf8)
    try "binary".write(to: dir.appendingPathComponent("Benchmarks/.build/release/Bench"),
                       atomically: true, encoding: .utf8)
    try "dep".write(
        to: dir.appendingPathComponent("Benchmarks/.build/checkouts/benchmark/Sources/X.swift"),
        atomically: true, encoding: .utf8)
    try "bench".write(to: dir.appendingPathComponent("Benchmarks/Benchmarks/Bench/B.swift"),
                      atomically: true, encoding: .utf8)
    try "manifest".write(to: dir.appendingPathComponent("Benchmarks/Package.swift"),
                         atomically: true, encoding: .utf8)

    let inventory = try BaselineRunner.treeInventory(repo: dir, scope: ["Sources/**"])
    // The nested package's SOURCES are out of scope, so they are frozen by
    // this inventory -- which is what stops a benchmark being rewritten
    // through the one door gate 1 cannot see.
    #expect(inventory["Benchmarks/Benchmarks/Bench/B.swift"] != nil)
    #expect(inventory["Benchmarks/Package.swift"] != nil)
    // Its BUILD OUTPUT is not, at any depth. Hashing it would be hundreds of
    // megabytes per eval and would refuse on the next one, because a build
    // directory changes every time anything is built.
    #expect(inventory.keys.allSatisfy { !$0.contains("/.build/") },
            "gate 2c walked into a nested .build: \(inventory.keys.sorted())")
    // And the in-scope library is exempt, as it always was.
    #expect(inventory["Sources/Lib/Lib.swift"] == nil)
}

/// GATE 2b. `isHarnessOutput` decides what the IGNORED inventory records, and
/// it used to match `.build` only at the repository root -- so a nested
/// package's `.build` (which git reports as one collapsed ignored record)
/// would have been walked and hashed in full, then reported as changed on the
/// very next eval. Making it agree with `neverWalkedDirectories` is a
/// correction, not a widening: the tree it now exempts here is one the other
/// two inventories were already stepping over.
@Test func gate2bTreatsANestedBuildDirectoryAsHarnessOutput() {
    #expect(BaselineRunner.isHarnessOutput("Benchmarks/.build"))
    #expect(BaselineRunner.isHarnessOutput("Benchmarks/.build/"))
    #expect(BaselineRunner.isHarnessOutput("Benchmarks/.build/release/Bench"))
    #expect(BaselineRunner.isHarnessOutput("dev/Benchmarks/.build/checkouts/x/y.swift"))
    // The root's behaviour is unchanged.
    #expect(BaselineRunner.isHarnessOutput(".build/release/Bench"))
    #expect(BaselineRunner.isHarnessOutput("results.tsv"))
    // And nothing else got exempted. `results.tsv` and `run.log` stay
    // ROOT-relative: this tool writes each at exactly one place, and a
    // `Benchmarks/results.tsv` is not one of them, so it stays inventoried.
    #expect(!BaselineRunner.isHarnessOutput("Benchmarks/results.tsv"))
    #expect(!BaselineRunner.isHarnessOutput("Benchmarks/run.log"))
    #expect(!BaselineRunner.isHarnessOutput(".buildkite/pipeline.yml"))
    #expect(!BaselineRunner.isHarnessOutput("Benchmarks/.BUILD/x"))
    #expect(!BaselineRunner.isHarnessOutput("Benchmarks/Package.swift"))
}

// =========================================================================
// MARK: - Gate 2d: the nested package's own dependency checkouts
// =========================================================================

/// Builds a directory holding one dependency checkout under
/// `<package>/.build/checkouts/benchmark/`, and returns its inventory.
private func makeCheckout(_ side: URL, packagePath: String?, body: String) throws {
    let root = BenchmarkPackage.directory(in: side, path: packagePath)
        .appendingPathComponent(".build/checkouts/benchmark/Sources/Benchmark")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body.write(to: root.appendingPathComponent("BenchmarkExecutor.swift"),
                   atomically: true, encoding: .utf8)
}

/// GATE 2d. The nested package resolves its OWN `Package.resolved` into its
/// OWN `.build/checkouts` -- its own copy of `ordo-one/package-benchmark`,
/// `BenchmarkPlugin` included, which the benchmark build EXECUTES. Measured
/// before the root-package version of this gate existed, with one `sed` into a
/// dependency's timer and a comment-only commit: `rc 0, verdict keep, ratio
/// 0.0099977`. Nothing about that argument changes when the dependency is
/// nested; only the path does.
@Test func gate2dRefusesATamperedCheckoutInTheNestedBenchmarkPackage() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: worktree)
    }
    let honest = "add(Int(nanoSeconds))\n"
    try makeCheckout(repo, packagePath: "Benchmarks", body: honest)
    try makeCheckout(worktree, packagePath: "Benchmarks", body: honest)

    let recorded = try BaselineRunner.checkoutInventory(in: repo, packagePath: "Benchmarks")
    #expect(!recorded.isEmpty)
    var record = BaselineRecord(
        tag: "t", frozenCommit: "a", measurementCommit: "a", configSHA256: "c",
        packageSwiftSHA256: "p", packageResolvedSHA256: "r", toolVersion: "v",
        manifestSHA256: [:], treeSHA256: [:], ignoredSHA256: [:], checkoutSHA256: [:],
        benchmarkCheckoutSHA256: recorded)

    // Clean: nothing to say. The ROOT inventory is empty on both sides and
    // that is the tolerated "no checkouts at all" case, exactly as before.
    #expect(EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record,
        benchmarkPackagePath: "Benchmarks") == nil)

    // One `sed` into the dependency's timer, in the CANDIDATE's nested tree.
    try makeCheckout(repo, packagePath: "Benchmarks", body: "add(Int(nanoSeconds) / 100)\n")
    let candidateFailure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record, benchmarkPackagePath: "Benchmarks")
    #expect(candidateFailure?.reason == "dependency_checkout_modified")
    #expect(candidateFailure?.detail.contains("Benchmarks/.build/checkouts") == true)

    // ...and in the PINNED WORKTREE's, which is the side that is compiled
    // AFTER `swift test` has run the agent's code -- the seventeenth vector's
    // shape, one package down.
    try makeCheckout(repo, packagePath: "Benchmarks", body: honest)
    try makeCheckout(worktree, packagePath: "Benchmarks", body: "add(0)\n")
    let baselineFailure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record, benchmarkPackagePath: "Benchmarks")
    #expect(baselineFailure?.reason == "dependency_checkout_modified")
    #expect(baselineFailure?.detail.contains("the pinned measurement worktree") == true)

    // THE PROOF THAT THIS IS NEW COVERAGE, not a restatement of the root
    // gate: the identical tamper, asked the way the code asked before this
    // feature -- with no nested package path -- is not seen at all.
    try makeCheckout(worktree, packagePath: "Benchmarks", body: "add(0)\n")
    record.checkoutSHA256 = [:]
    #expect(EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: worktree, record: record, benchmarkPackagePath: nil) == nil,
        "the root-only gate saw a nested-package tamper; the test no longer proves anything")
}

/// "There is no record" must never read as "there is nothing to check" -- the
/// ruling the three existing inventories already made. Here the trigger is the
/// CONFIG, whose bytes gate 2 has already pinned: a baseline taken before
/// `benchmark_package_path` was added to config.yaml never looked at the
/// nested tree, so it cannot vouch for it.
@Test func gate2dRefusesANestedPackageTheBaselineNeverInventoried() throws {
    let repo = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: repo) }
    try makeCheckout(repo, packagePath: "Benchmarks", body: "x\n")

    let record = BaselineRecord(
        tag: "t", frozenCommit: "a", measurementCommit: "a", configSHA256: "c",
        packageSwiftSHA256: "p", packageResolvedSHA256: "r", toolVersion: "v",
        manifestSHA256: [:], treeSHA256: [:], ignoredSHA256: [:], checkoutSHA256: [:],
        benchmarkCheckoutSHA256: nil)

    let failure = EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: repo, record: record, benchmarkPackagePath: "Benchmarks")
    #expect(failure?.reason == "baseline_predates_tree_inventory")
    #expect(failure?.detail.contains("benchmark_package_path") == true)

    // A ROOT-layout run with the same nil field is NOT refused: there is
    // genuinely no second tree, and that is what nil has always meant here.
    #expect(EvalRunner.checkoutIntegrityFailure(
        repo: repo, worktree: repo, record: record, benchmarkPackagePath: nil) == nil)
}

// =========================================================================
// MARK: - init, against a real nested-layout package
// =========================================================================

/// A git repository laid out the way the ecosystem lays one out: a library in
/// the root package, and a nested `Benchmarks/Package.swift` whose target
/// depends on a product named `Benchmark`.
///
/// The `Benchmark` product comes from a LOCAL path dependency rather than from
/// `ordo-one/package-benchmark`, so the whole fixture describes and resolves
/// with no network at all -- the same constraint `makeGitFixture` is built
/// under. What `init` keys on is the product NAME (`productDependencies`
/// containing "Benchmark"), which is identical either way.
///
/// `nestedSourceControlDependency` adds a REAL `sourceControl` dependency to
/// the NESTED package only -- a second, local git repository consumed by
/// `file://` URL, the same offline device `makeDependentGitFixture` uses -- so
/// `Benchmarks/Package.resolved` becomes a file SwiftPM insists on producing.
/// That is the shape every real adopter has, because
/// `ordo-one/package-benchmark` is declared by the nested manifest and by
/// nothing else.
private func makeNestedBenchmarkFixture(
    rootAlsoHasBenchmarks: Bool = false, nestedSourceControlDependency: Bool = false
) throws -> URL {
    // The repository directory is named `repo`, not a UUID, and that is
    // load-bearing rather than cosmetic: SwiftPM derives a path dependency's
    // package IDENTITY from its directory name, so `.package(path: "../")`
    // referenced as `package: "repo"` only resolves if the directory really
    // is called that. A UUID-named repository fails with "unknown package",
    // which is exactly what a real nested benchmark package does NOT do --
    // `Benchmarks/Package.swift` in `apple/swift-asn1` says
    // `package: "swift-asn1"`, matching its checkout directory.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("repo")
    func mk(_ p: String) throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(p), withIntermediateDirectories: true)
    }
    func write(_ p: String, _ body: String) throws {
        try body.write(to: dir.appendingPathComponent(p), atomically: true, encoding: .utf8)
    }
    try mk("Sources/Lib")
    try mk("Tests/LibTests")
    try mk("BenchDep/Sources/Benchmark")
    try mk("Benchmarks/Benchmarks/LibBenchmark")

    // The `sourceControl` dependency, when asked for: a sibling git repository
    // of the fixture (NOT inside it), so nothing about it is inventoried by the
    // repository's own gates, reached by `file://` so no network is involved.
    var nestedDependencyDeclaration = ""
    var nestedDependencyProduct = ""
    if nestedSourceControlDependency {
        let dep = dir.deletingLastPathComponent().appendingPathComponent("dep")
        try FileManager.default.createDirectory(
            at: dep.appendingPathComponent("Sources/DepLib"), withIntermediateDirectories: true)
        try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "DepLib",
                products: [.library(name: "DepLib", targets: ["DepLib"])],
                targets: [.target(name: "DepLib")]
            )
            """.write(to: dep.appendingPathComponent("Package.swift"),
                      atomically: true, encoding: .utf8)
        try "public func depThing() -> Int { 7 }\n".write(
            to: dep.appendingPathComponent("Sources/DepLib/DepLib.swift"),
            atomically: true, encoding: .utf8)
        let depSetup = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
            git init -q -b main . && git config user.name Test && git config user.email t@example.com \
            && git add -A && git commit -q -m dep && git tag 1.0.0
            """], cwd: dep, env: nil, timeout: 120)
        #expect(depSetup.exitCode == 0, "dependency repo setup failed: \(depSetup.stderr)")
        nestedDependencyDeclaration = "        .package(url: \"file://\(dep.path)\", from: \"1.0.0\"),\n"
        nestedDependencyProduct = "                .product(name: \"DepLib\", package: \"dep\"),\n"
    }

    try write("Sources/Lib/Lib.swift", "public func f() -> Int { 1 }\n")
    try write("Tests/LibTests/LibTests.swift", """
        import Testing
        @testable import Lib
        @Test func fReturnsOne() { #expect(f() == 1) }
        """)
    try write("BenchDep/Sources/Benchmark/Benchmark.swift", "public func noop() {}\n")
    try write("BenchDep/Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "BenchDep",
            products: [.library(name: "Benchmark", targets: ["Benchmark"])],
            targets: [.target(name: "Benchmark")]
        )
        """)

    let rootBenchTarget = rootAlsoHasBenchmarks ? """
        ,
                .executableTarget(
                    name: "RootBench",
                    dependencies: [.product(name: "Benchmark", package: "BenchDep")],
                    path: "RootBenchmarks/RootBench")
        """ : ""
    if rootAlsoHasBenchmarks {
        // NOT under Sources/: `deriveScope` excludes every target sharing a
        // benchmark target's PARENT directory (its only automatic exclusion,
        // and a deliberately conservative one), so a root benchmark at
        // Sources/RootBench would take Sources/Lib out of scope with it and
        // `init` would refuse with `emptyScope` -- correctly, and for a
        // reason that has nothing to do with what this test is about.
        try mk("RootBenchmarks/RootBench")
        // A REAL declaration, not a commented-out one:
        // `discoverBenchmarks(benchmarkSource:)` searches the
        // comment-and-string-stripped text, so `// Benchmark("X")` discovers
        // nothing and `init` refuses with `noBenchmarks` -- correctly, and
        // for a reason that has nothing to do with what this test is about.
        try write("RootBenchmarks/RootBench/main.swift", """
            import Benchmark
            nonisolated(unsafe) let benchmarks = {
                Benchmark("RootOnly") { _ in }
            }
            let x = 1
            """)
    }
    try write("Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "root",
            products: [.library(name: "Lib", targets: ["Lib"])],
            dependencies: [\(rootAlsoHasBenchmarks ? ".package(path: \"BenchDep\")" : "")],
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"])\(rootBenchTarget)
            ]
        )
        """)

    try write("Benchmarks/Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "benchmarks",
            dependencies: [
                .package(path: "../"),
                .package(path: "../BenchDep"),
        \(nestedDependencyDeclaration)    ],
            targets: [
                .executableTarget(
                    name: "LibBenchmark",
                    dependencies: [
                        .product(name: "Benchmark", package: "BenchDep"),
                        .product(name: "Lib", package: "repo"),
        \(nestedDependencyProduct)            ],
                    path: "Benchmarks/LibBenchmark")
            ]
        )
        """)
    try write("Benchmarks/Benchmarks/LibBenchmark/Bench.swift", """
        import Benchmark
        nonisolated(unsafe) let benchmarks = {
            Benchmark("ParseWebPKI") { _ in }
            Benchmark("Encode") { _ in }
        }
        let x = 1
        """)
    try write(".gitignore", ".build/\nresults.tsv\nrun.log\n")

    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", """
        git init -q . && git config user.name Test && git config user.email t@example.com \
        && git add -A && git commit -q -m one
        """], cwd: dir, env: nil, timeout: 60)
    #expect(r.exitCode == 0, "fixture setup failed: \(r.stderr)")
    return dir
}

/// THE HEADLINE. Before this change `init` scanned the root manifest only,
/// found no benchmark target, and answered "No benchmarks found, so no config
/// was written" (rc 1) on every repository laid out this way -- which is every
/// real adopter of `ordo-one/package-benchmark` that was surveyed.
@Test func initDiscoversBenchmarksInANestedPackage() throws {
    let repo = try makeNestedBenchmarkFixture()
    defer { try? FileManager.default.removeItem(at: repo) }

    let outcome = try InitRunner.runReportingCommit(repo: repo, force: false)
    let config = outcome.config
    #expect(config.benchmarkPackagePath == "Benchmarks")
    #expect(config.benchmarkTarget == "LibBenchmark")
    #expect(config.benchmarks.sorted() == ["Encode", "ParseWebPKI"])
    // SCOPE COMES FROM THE ROOT PACKAGE. The agent edits the library; the
    // benchmark package's own sources must never be in scope, or an agent
    // that can rewrite the benchmark can make it measure less work.
    #expect(config.scope == ["Sources/Lib/**"])
    #expect(!config.scope.contains { $0.hasPrefix("Benchmarks") })
    #expect(!outcome.notes.isEmpty)
    #expect(outcome.notes.joined().contains("Benchmarks/"))

    // The written file carries the key, and reading it back agrees.
    let written = try Config.load(repo.appendingPathComponent(".autor3search/config.yaml"))
    #expect(written.benchmarkPackagePath == "Benchmarks")
    #expect(written.benchmarkTarget == "LibBenchmark")
}

/// The stated preference, bound so it cannot drift: when BOTH packages declare
/// benchmark targets the ROOT wins, because that is the no-change branch for
/// every repository configured before this feature existed -- and the human is
/// TOLD, by name, that the other candidate exists.
@Test func whenBothPackagesHaveBenchmarksTheRootPackageWins() throws {
    let repo = try makeNestedBenchmarkFixture(rootAlsoHasBenchmarks: true)
    defer { try? FileManager.default.removeItem(at: repo) }

    let outcome = try InitRunner.runReportingCommit(repo: repo, force: false)
    #expect(outcome.config.benchmarkPackagePath == nil)
    #expect(outcome.config.benchmarkTarget == "RootBench")
    let note = outcome.notes.joined(separator: "\n")
    #expect(note.contains("chose the ROOT package"))
    #expect(note.contains("LibBenchmark"), "the note must name the target it did NOT pick")
    #expect(note.contains("benchmark_package_path: Benchmarks"))
}

/// GATE 3 AND THE FREEZE SET. A benchmark target in a nested package is
/// exactly as rewritable as one in the root package, and an agent that can
/// rewrite the benchmark can make it measure less work. `baseline` describes
/// BOTH packages and freezes the union, re-rooting the nested paths through
/// `BenchmarkPackage.repoRelative` so everything downstream stays
/// repo-relative.
@Test func baselineFreezesTheNestedPackagesBenchmarkSources() throws {
    let repo = try makeNestedBenchmarkFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo, env: env) }

    try InitRunner.run(repo: repo, force: false)
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                               ["-c", "git add -A && git commit -q -m config"],
                               cwd: repo, env: nil, timeout: 60)
    #expect(r.exitCode == 0)

    _ = try BaselineRunner.run(repo: repo, tag: "t", env: env)
    let home = try StateHome(repo: repo, env: env)
    let snapshot = try FrozenSnapshot.load(
        try home.runDir(tag: "t").appendingPathComponent("frozen-manifest.json"))

    #expect(snapshot.directories.contains("Benchmarks/Benchmarks/LibBenchmark"),
            "frozen directories were \(snapshot.directories)")
    #expect(snapshot.directories.contains("Tests/LibTests"))
    #expect(snapshot.manifest.keys.contains("Benchmarks/Benchmarks/LibBenchmark/Bench.swift"),
            "frozen manifest was \(snapshot.manifest.keys.sorted())")

    // GATE 2a. The nested manifest is inventoried and hashed -- by
    // `ScopeGate.isManifestPath`, which matches `Package.swift` on the LAST
    // path component and so has always covered a nested one. Bound here
    // because "already covered" is a claim, and a claim about a security gate
    // is worth what the test behind it is worth.
    let record = try BaselineRecord.load(try home.baselineRecordURL(tag: "t"))
    #expect(record.manifestSHA256?["Benchmarks/Package.swift"] != nil,
            "manifest inventory was \(record.manifestSHA256?.keys.sorted() ?? [])")
    #expect(record.manifestSHA256?["Package.swift"] != nil)
    // GATE 2c. The nested benchmark's sources are outside `scope`, so the
    // out-of-scope inventory freezes them too -- a second, independent lock on
    // the same file.
    #expect(record.treeSHA256?["Benchmarks/Benchmarks/LibBenchmark/Bench.swift"] != nil)
    // GATE 2d. A nested-package inventory exists, even when it is empty:
    // `nil` has to keep meaning "never looked", and this run did look.
    #expect(record.benchmarkCheckoutSHA256 != nil)
    // And no inventory walked either `.build`.
    #expect(record.treeSHA256?.keys.allSatisfy { !$0.contains(".build/") } == true)
    #expect(record.manifestSHA256?.keys.allSatisfy { !$0.contains(".build/") } == true)
}

// =========================================================================
// MARK: - `profile` -- the command that ignored the key entirely
// =========================================================================

/// A minimal nested-layout repository whose benchmark package declares BOTH
/// executables `profile` builds by name, and whose ROOT package declares
/// NEITHER.
///
/// That asymmetry is the test. `Sampler.profile` used to build with the
/// repository root as the package and look for the products under
/// `<repo>/.build/release/`, so against a real nested-layout repository it
/// died before it profiled anything:
///
///     could not build SwiftASN1Benchmark: error: Could not find target named
///     'SwiftASN1Benchmark-product'
///
/// -- measured on a local clone of `apple/swift-asn1`; see docs/run-log.md,
/// "Run: apple/swift-asn1, baseline asn1run", §"What `profile` said". Nothing
/// here needs git, a CPU sampler, or the network: the point is purely which
/// package gets built and where the result is looked for.
///
/// The directory is called `repo` for the same reason
/// `makeNestedBenchmarkFixture`'s is -- SwiftPM derives a path dependency's
/// identity from the directory name, so `package: "repo"` only resolves if the
/// directory really is called that.
private func makeNestedProfileFixture() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("repo")
    func mk(_ p: String) throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(p), withIntermediateDirectories: true)
    }
    func write(_ p: String, _ body: String) throws {
        try body.write(to: dir.appendingPathComponent(p), atomically: true, encoding: .utf8)
    }
    try mk("Sources/Lib")
    try mk("Benchmarks/Sources/NestedBench")
    try mk("Benchmarks/Sources/BenchmarkTool")

    try write("Sources/Lib/Lib.swift", "public func f() -> Int { 1 }\n")
    try write("Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "repo",
            products: [.library(name: "Lib", targets: ["Lib"])],
            targets: [.target(name: "Lib")]
        )
        """)
    try write("Benchmarks/Package.swift", """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "benchmarks",
            products: [
                .executable(name: "NestedBench", targets: ["NestedBench"]),
                .executable(name: "BenchmarkTool", targets: ["BenchmarkTool"]),
            ],
            dependencies: [.package(path: "../")],
            targets: [
                .executableTarget(
                    name: "NestedBench",
                    dependencies: [.product(name: "Lib", package: "repo")]),
                .executableTarget(name: "BenchmarkTool"),
            ]
        )
        """)
    try write("Benchmarks/Sources/NestedBench/main.swift", "import Lib\nprint(f())\n")
    try write("Benchmarks/Sources/BenchmarkTool/main.swift", "print(\"tool\")\n")
    return dir
}

/// THE BUG, BOUND. `profile` must resolve the benchmark package exactly the way
/// `eval` does -- through `Config.benchmarkPackage(in:)`, i.e.
/// `BenchmarkPackage.directory`, the one place that knows where the benchmark
/// package is -- and find both products under `<benchPath>/.build/release/`.
///
/// The first assertion is the pre-condition that makes this a real regression
/// test rather than a restatement: a build aimed at the repository ROOT cannot
/// produce these products at all, which is exactly what the shipped `profile`
/// was doing. It is measured here rather than asserted from memory.
///
/// Split out of `profile` itself because `profile` refuses up front on a
/// machine with no permitted CPU sampler, and a test reachable only through it
/// would silently do nothing on Linux. `doctor` warns about conditionally-gated
/// tests, so the seam is in the code rather than an `.enabled(if:)` here.
@Test func profileBuildsAndLocatesTheBenchmarkBinariesInTheNestedPackage() throws {
    let repo = try makeNestedProfileFixture()
    defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }

    var config = InitRunner.defaultConfig(
        scope: ["Sources/Lib/**"], benchmarkTarget: "NestedBench", benchmarks: ["A"],
        benchmarkPackagePath: "Benchmarks")

    // Pre-condition: the ROOT package has no such product, so the old geometry
    // could not have worked here -- or on any repository laid out this way.
    let atRoot = try Subprocess.run(
        URL(fileURLWithPath: "/usr/bin/swift"),
        ["build", "-c", "release", "--product", "NestedBench"],
        cwd: repo, env: nil, timeout: 600)
    #expect(atRoot.exitCode != 0,
            "the fixture is wrong: the root package must NOT be able to build NestedBench")

    let exe = try Sampler.buildAndLocateBenchmarkExecutable(
        repo: repo, config: config, timeout: 600)
    let expected = repo.appendingPathComponent("Benchmarks/.build/release/NestedBench")
    #expect(exe.standardizedFileURL.path == expected.standardizedFileURL.path,
            "profile located \(exe.path)")
    #expect(FileManager.default.isExecutableFile(atPath: exe.path))

    // BenchmarkTool too: it is a product of the package that declares the
    // benchmark dependency, which in this layout is not the root one.
    let both = Sampler.measuredBinaries(repo: repo, config: config)
    #expect(both.target.standardizedFileURL.path == exe.standardizedFileURL.path)
    #expect(FileManager.default.isExecutableFile(atPath: both.tool.path),
            "BenchmarkTool was expected at \(both.tool.path)")

    // Nothing landed at the repository root, which is where the old code looked.
    #expect(!FileManager.default.fileExists(
        atPath: repo.appendingPathComponent(".build/release/NestedBench").path))

    // AND THE ROOT LAYOUT IS UNCHANGED. Every config written before this key
    // existed omits it, and for those `profile` must address the repository
    // itself, exactly as it always did.
    config.benchmarkPackagePath = nil
    #expect(Sampler.benchmarkPackageRoot(repo: repo, config: config).path == repo.path)
    #expect(Sampler.measuredBinaries(repo: repo, config: config).target.path
        == repo.appendingPathComponent(".build/release/NestedBench").path)
}

// =========================================================================
// MARK: - The two gaps a reviewer named
// =========================================================================

/// GAP 1. `BenchmarkPackage.validate` decided "this is a real package
/// directory" with `fileExists`, WHICH FOLLOWS SYMLINKS. A `Benchmarks`
/// symlink pointing outside the repository therefore satisfied it, and the
/// gates then disagree about what they can see: `FileManager.enumerator` does
/// not descend a symlinked directory, so gates 2a and 2c never look inside it,
/// while gate 2d addresses `<path>/.build/checkouts` by path and does follow
/// it. The result is a package compiled into the measured binary out of a tree
/// no inventory covers.
///
/// Not reachable by the agent -- planting it needs operator setup that
/// pre-dates the baseline, and gate 2b reports a link that appears afterwards
/// -- which is why it is a containment check rather than a new gate.
///
/// The `manifestInventory` assertion is the live half: it is the real gate 2a
/// walk, run against this exact tree, showing the nested manifest genuinely
/// missing rather than asserted to be.
@Test func aBenchmarkPackageReachedThroughASymlinkOutOfTheRepositoryIsRefused() throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let repo = parent.appendingPathComponent("repo")
    let outside = parent.appendingPathComponent("outside")
    let fm = FileManager.default
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: parent) }

    try "// swift-tools-version: 6.0\n".write(
        to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "// swift-tools-version: 6.0\n".write(
        to: outside.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(at: repo.appendingPathComponent("Benchmarks"),
                              withDestinationURL: outside)

    // The shape rule sees nothing wrong -- there is no ".." to find -- and
    // `fileExists` follows the link, so the pre-fix check was satisfied.
    try BenchmarkPackage.validateShape("Benchmarks")
    #expect(fm.fileExists(atPath: repo.appendingPathComponent("Benchmarks/Package.swift").path),
            "the premise of this test is that fileExists follows the link")

    // Gate 2a's own walk, run for real: the nested manifest is invisible.
    let inventory = try BaselineRunner.manifestInventory(repo: repo)
    #expect(inventory["Package.swift"] != nil)
    #expect(inventory["Benchmarks/Package.swift"] == nil,
            "manifest inventory saw \(inventory.keys.sorted())")

    #expect(throws: BenchmarkPackage.Invalid.self) {
        try BenchmarkPackage.validate("Benchmarks", in: repo)
    }
    var config = InitRunner.defaultConfig(
        scope: ["Sources/**"], benchmarkTarget: "B", benchmarks: ["A"],
        benchmarkPackagePath: "Benchmarks")
    #expect(throws: (any Error).self) { try config.validateBenchmarkPackage(in: repo) }

    // A REAL directory in the same place is still accepted -- the check is
    // containment, not a ban on the name.
    try fm.removeItem(at: repo.appendingPathComponent("Benchmarks"))
    try fm.createDirectory(at: repo.appendingPathComponent("Benchmarks"),
                           withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\n".write(
        to: repo.appendingPathComponent("Benchmarks/Package.swift"),
        atomically: true, encoding: .utf8)
    try BenchmarkPackage.validate("Benchmarks", in: repo)
    try config.validateBenchmarkPackage(in: repo)
    #expect(try BaselineRunner.manifestInventory(repo: repo)["Benchmarks/Package.swift"] != nil)
}

/// GAP 1, THE OTHER HALF: a repository whose own path runs through a symlink
/// must NOT be refused. On macOS that is the ordinary case, not an exotic one
/// -- `NSTemporaryDirectory()` hands back `/var/folders/...`, and `/var` is a
/// symlink to `/private/var` -- so a containment check that resolved only the
/// child would refuse every fixture in this file.
@Test func aRepositoryReachedThroughASymlinkIsNotItselfAnEscape() throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let real = parent.appendingPathComponent("real")
    let fm = FileManager.default
    try fm.createDirectory(at: real.appendingPathComponent("Benchmarks"),
                           withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: parent) }
    try "// swift-tools-version: 6.0\n".write(
        to: real.appendingPathComponent("Benchmarks/Package.swift"),
        atomically: true, encoding: .utf8)

    let link = parent.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    try BenchmarkPackage.validate("Benchmarks", in: link)
}

/// GAP 2. `resolveLockfilePin` asked its three questions of the ROOT package
/// only. A nested benchmark package has its own manifest and its own
/// dependency set -- it is the package that declares
/// `ordo-one/package-benchmark` -- so a nested package with source-control
/// dependencies and no tracked `Package.resolved` PASSED `baseline`, and then
/// the first `eval`'s own `swift build --product BenchmarkTool` created
/// `Benchmarks/Package.resolved`. Gate 2a treats a manifest appearing where
/// baseline recorded none as a mismatch, so every experiment after that is
/// `manifest_change_rejected`, permanently, because `frozenCommit` never
/// advances. That is the exact defect `resolveLockfilePin` exists to prevent,
/// reached one directory down.
///
/// Refused UP FRONT now, the same as for the root package. The lockfile is
/// removed from git after `init` has committed it, because `init` is what
/// normally prevents this state -- the repository this has to protect is one
/// configured by hand, by an older `init`, or with the lockfile re-ignored
/// afterwards (a bare `Package.resolved` line in `.gitignore` matches at any
/// depth, which is how `apple/swift-asn1` presented).
@Test func baselineRefusesANestedPackageWithUnpinnedDependencies() throws {
    let repo = try makeNestedBenchmarkFixture(nestedSourceControlDependency: true)
    let env = isolatedStateEnv()
    defer {
        cleanUpFixture(repo: repo.deletingLastPathComponent(), env: env)
    }

    try InitRunner.run(repo: repo, force: false)
    let sh = URL(fileURLWithPath: "/bin/sh")
    let setup = try Subprocess.run(sh, ["-c", """
        git add -A && git commit -q -m config \
        && git rm -q --cached Benchmarks/Package.resolved \
        && rm -f Benchmarks/Package.resolved \
        && printf 'Package.resolved\\n' >> .gitignore \
        && git add -A && git commit -q -m unpin
        """], cwd: repo, env: nil, timeout: 120)
    #expect(setup.exitCode == 0, "\(setup.stderr)")
    #expect(!FileManager.default.fileExists(
        atPath: repo.appendingPathComponent("Benchmarks/Package.resolved").path),
            "the state being refused is: no nested lockfile, and git is not tracking one")

    do {
        _ = try BaselineRunner.run(repo: repo, tag: "nestedlock", env: env)
        Issue.record("baseline accepted a nested benchmark package with no tracked lockfile")
    } catch let error as BaselineError {
        let text = "\(error)"
        #expect(text.contains("Benchmarks/Package.resolved"),
                "the refusal must name the nested lockfile by its repo-relative path: \(text)")
        #expect(text.contains("Benchmarks/"),
                "the refusal must say WHICH package it is about: \(text)")
    }
}

/// And the root package's own behaviour is untouched by that change: a package
/// with no external dependencies anywhere in its graph still records "absent",
/// and a nested package that genuinely has no source-control dependencies --
/// the fixture's default, whose nested manifest declares only path
/// dependencies -- still baselines cleanly.
@Test func aNestedPackageWithOnlyPathDependenciesStillBaselines() throws {
    let repo = try makeNestedBenchmarkFixture()
    let env = isolatedStateEnv()
    defer { cleanUpFixture(repo: repo.deletingLastPathComponent(), env: env) }

    try InitRunner.run(repo: repo, force: false)
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                               ["-c", "git add -A && git commit -q -m config"],
                               cwd: repo, env: nil, timeout: 60)
    #expect(r.exitCode == 0)

    let record = try BaselineRunner.run(repo: repo, tag: "pathonly", env: env)
    #expect(record.packageResolvedSHA256 == Lockfile.absentPin,
            "got \(record.packageResolvedSHA256)")
}

// =========================================================================
// MARK: - helpers
// =========================================================================

/// Decodes a `Config` straight from YAML text, which is what `Config.load`
/// does after reading a file. Kept local rather than added to `Config`: these
/// tests are the only caller, and widening a frozen type's surface for a test
/// helper is how a type stops being frozen.
private func YAMLDecodedConfig(_ text: String) throws -> Config {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.yaml")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return try Config.load(url)
}
