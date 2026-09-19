// Sources/AutoR3SearchKit/SwiftPM/BenchmarkPackage.swift
//
// THE ONE PLACE THAT KNOWS WHERE THE BENCHMARK PACKAGE IS.
//
// A repository can declare its benchmark target in its ROOT `Package.swift`
// (what `Fixtures/DemoPackage` does, and what every version of this tool
// before `benchmark_package_path` assumed), or in a NESTED SwiftPM package --
// conventionally `Benchmarks/Package.swift`, declaring `.package(path: "../")`
// plus `ordo-one/package-benchmark`, with the benchmark target's sources at
// `Benchmarks/Benchmarks/<Target>/`. The nested layout is what the ecosystem
// actually uses: `apple/swift-asn1`, `apple/swift-log`, `GraphQLSwift/GraphQL`
// and `CoreOffice/XMLCoder` are all laid out that way and NONE of them has a
// benchmark target in its root package.
//
// A nested package brings a SECOND `.build` tree, a SECOND `Package.resolved`
// and a SECOND `.build/checkouts` into the repository under test. Every gate
// that protects the root package's equivalents has to protect these too, and
// the way to make that auditable rather than hopeful is to have exactly one
// function that answers "where is it?" and have every gate call it. That is
// this file. A gate that does not call something here is a gate that has not
// been extended.
import Foundation

/// Where the benchmark package lives, and whether a configured location is
/// one this tool is willing to address at all.
public enum BenchmarkPackage {
    /// The conventional directory name a nested benchmark package uses, and
    /// the only one `init` looks for automatically.
    ///
    /// `ordo-one/package-benchmark`'s own documentation, and every repository
    /// surveyed for this feature, put it here. `init` does not go hunting for
    /// nested `Package.swift` files anywhere else: a repository can contain
    /// many nested packages (vendored dependencies, sample projects, an
    /// integration-test fixture), and picking one of several by a heuristic
    /// is the kind of silent guess `InitError.multipleBenchmarkTargets`
    /// already refuses to make. An unconventional location is configured by
    /// hand, and the validation below is what makes that safe.
    public static let conventionalDirectory = "Benchmarks"

    /// Why a configured `benchmark_package_path` was refused.
    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case empty
        case absolute(String)
        case escapes(String)
        case unsafeComponent(path: String, component: String)
        case reservedComponent(path: String, component: String)
        case noManifest(path: String, expected: String)

        public var description: String {
            switch self {
            case .empty:
                return """
                    benchmark_package_path is empty. Omit the key entirely to mean "the \
                    repository root" -- that is what every config written before this key \
                    existed means, and an empty string is not a second spelling of it.
                    """
            case .absolute(let path):
                return """
                    benchmark_package_path "\(path)" is absolute. It must be relative to the \
                    repository root, because everything the gates freeze, hash and purge is \
                    addressed relative to the repository under test; an absolute path would \
                    let the measured build come from a tree no gate inventories. This is the \
                    same rule AUTOR3SEARCH_SWIFT_STATE_HOME enforces in the opposite \
                    direction, and for the same reason: a path whose meaning depends on where \
                    a command was invoked from, or on what is mounted, is not a path a gate \
                    can vouch for.
                    """
            case .escapes(let path):
                return """
                    benchmark_package_path "\(path)" leaves the repository (it contains a ".." \
                    component). The benchmark package must live INSIDE the repository under \
                    test: its sources are frozen, its manifests are hashed, its \
                    .build/checkouts are verified and its .build/plugins are purged, and every \
                    one of those is an inventory taken relative to the repository root. A \
                    package outside it would be compiled into the measured binary with none of \
                    that applied.
                    """
            case .unsafeComponent(let path, let component):
                return """
                    benchmark_package_path "\(path)" contains the component "\(component)", \
                    which is not a plain path component this tool will address. Components may \
                    contain only ASCII letters, digits, "-", "_" and "." -- the same rule run \
                    tags are held to (see StateHome), deliberately strict in the direction \
                    that fails loudly. Rename the directory, or move the benchmark package to \
                    "\(conventionalDirectory)".
                    """
            case .reservedComponent(let path, let component):
                return """
                    benchmark_package_path "\(path)" contains the component "\(component)", \
                    which this tool never walks and never inventories. A benchmark package \
                    under .git or .build would be compiled into the measured binary while \
                    every disk inventory skipped it, which is the whole class of bypass gates \
                    2a-2d exist to close.
                    """
            case .noManifest(let path, let expected):
                return """
                    benchmark_package_path "\(path)" does not contain a Package.swift \
                    (expected \(expected)). It must name a real SwiftPM package directory: it \
                    is what `swift package describe`, `swift build --package-path` and the \
                    measured binaries under <path>/.build/release/ are all addressed against. \
                    If the benchmarks live in the root package, omit the key.
                    """
            }
        }
    }

    /// Structural validation of `path`, with no filesystem access.
    ///
    /// REUSED, NOT REINVENTED. The per-component character rule is
    /// `StateHome.PathComponent`, the same predicate that decides whether a
    /// run tag may be turned into a directory under the state home, and for
    /// the identical reason: a component that is `.`, `..`, empty, or carries
    /// a separator is one that changes which directory a path denotes once it
    /// is standardized. Spelling that rule a second time here would be two
    /// rules to keep in step, and the gap between them would be the bypass.
    ///
    /// `.git` and `.build` are refused on top of that, because
    /// `BaselineRunner.neverWalkedDirectories` skips both at ANY depth -- so a
    /// benchmark package under either would be compiled while every disk
    /// inventory stepped over it.
    public static func validateShape(_ path: String) throws {
        guard !path.isEmpty else { throw Invalid.empty }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { throw Invalid.absolute(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            if component == ".." { throw Invalid.escapes(path) }
            guard StateHome.PathComponent.isSafe(component) else {
                throw Invalid.unsafeComponent(path: path, component: component)
            }
            if BaselineRunner.neverWalkedDirectories.contains(component) {
                throw Invalid.reservedComponent(path: path, component: component)
            }
        }
    }

    /// `validateShape`, plus the one thing only the disk can answer: the
    /// directory has to actually be a SwiftPM package.
    ///
    /// Separate from `validateShape` so `Config.validate()` -- which is called
    /// in places that have no repository URL to hand, including on a config
    /// constructed in a test -- can check everything that is checkable without
    /// I/O, and the callers that DO have a repository can additionally insist
    /// the manifest is there.
    public static func validate(_ path: String, in repo: URL) throws {
        try validateShape(path)
        let manifest = repo.appendingPathComponent(path).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw Invalid.noManifest(path: path, expected: manifest.path)
        }
    }

    /// The directory of the package that declares the benchmark target,
    /// inside `root`. `root` itself when `path` is `nil`.
    ///
    /// `root` is the side being addressed -- the repository under test on the
    /// candidate side, the pinned measurement worktree on the baseline side --
    /// which is what makes the same geometry apply to both without a second
    /// code path. The baseline side's nested package is at exactly the same
    /// relative location as the candidate's, because the worktree is a
    /// checkout of a commit of the same repository.
    public static func directory(in root: URL, path: String?) -> URL {
        guard let path, !path.isEmpty else { return root }
        return root.appendingPathComponent(path)
    }

    /// A path reported relative to the BENCHMARK PACKAGE, re-rooted to be
    /// relative to the REPOSITORY.
    ///
    /// `swift package describe` run against `Benchmarks/` reports its
    /// benchmark target's path as `Benchmarks/SwiftASN1Benchmark` -- relative
    /// to that package, not to the repository. Everything downstream of it
    /// (the freeze set, `FrozenSnapshot.directories`, gate 4's new-file scan)
    /// is repo-relative, so the two must be joined exactly once and in exactly
    /// one place. The result for the example above is
    /// `Benchmarks/Benchmarks/SwiftASN1Benchmark`, which is where those
    /// sources really are.
    public static func repoRelative(_ relative: String, under path: String?) -> String {
        guard let path, !path.isEmpty else { return relative }
        return "\(path)/\(relative)"
    }
}

extension Config {
    /// The directory of the package that declares `benchmarkTarget`, inside
    /// `root`.
    public func benchmarkPackage(in root: URL) -> URL {
        BenchmarkPackage.directory(in: root, path: benchmarkPackagePath)
    }

    /// Whether this configuration uses a nested benchmark package at all.
    public var hasNestedBenchmarkPackage: Bool {
        guard let p = benchmarkPackagePath else { return false }
        return !p.isEmpty
    }

    /// Every SwiftPM package root inside one SIDE that this tool builds in,
    /// paired with a human label naming it -- the repository (or worktree)
    /// itself, and the nested benchmark package when there is one.
    ///
    /// THIS IS THE PARITY SEAM. Gate 4b purges `.build/plugins` under each of
    /// these, gate 6b purges them again, and the `purge_build_output` opt-in
    /// clears each one's build output. A nested `.build/plugins` is what
    /// actually EXECUTES during the benchmark build, so a purge that covered
    /// only the root would be a purge of the tree that matters least. Having
    /// one function produce the list means a future gate gets both roots by
    /// calling it rather than by remembering to.
    ///
    /// Deduplicated by construction: in the root-package layout the nested
    /// entry is absent entirely, so nothing is purged or hashed twice and the
    /// messages a root-layout repository produces are unchanged.
    public func buildRoots(in side: URL, sideDescription: String) -> [(URL, String)] {
        var roots = [(side, sideDescription)]
        if let path = benchmarkPackagePath, !path.isEmpty {
            roots.append((side.appendingPathComponent(path),
                          "the nested benchmark package at \(path)/ in \(sideDescription)"))
        }
        return roots
    }
}
