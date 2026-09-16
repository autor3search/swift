import Foundation

/// The first gate in the evaluation chain: it must reject before anything is
/// built or measured.
///
/// Two independent checks, both load-bearing:
///
/// 1. **Manifest rejection.** Any change to `Package.swift` or
///    `Package.resolved` is rejected outright, regardless of scope.
///    `Package.swift` is not just a dependency list — it is the build-flag
///    surface (`swiftSettings`, `unsafeFlags`, `-Ounchecked`,
///    `-enforce-exclusivity=unchecked`) and an executable Swift program run
///    at build time. Without this, an agent could "win" by turning off
///    bounds checking instead of writing faster code.
/// 2. **Scope enforcement.** Every other changed path must fall under one of
///    the config's declared `scope` globs. This is what stops an agent
///    editing a benchmark *helper* target — one holding fixture data or a
///    synthetic dataset, consumed by the benchmark but not itself importing
///    the benchmark library, so it sits outside the frozen set (freeze
///    detection keys on the benchmark product dependency) — to shrink the
///    benchmark's real workload. Rejecting the edit here, before measurement,
///    is the only thing stopping that.
public enum ScopeGate {
    /// Changes to these paths are rejected unconditionally, before the scope
    /// check even runs. Compared to `changedPaths` by exact value: git
    /// records the manifest at the repository root under these exact names,
    /// so no glob is needed.
    public static let manifestPaths: Set<String> = ["Package.swift", "Package.resolved"]

    /// Whether `path` falls under `glob`.
    ///
    /// Supports three forms:
    /// - `"**"` matches everything.
    /// - `"<prefix>/**"` matches `<prefix>` and everything under it, any
    ///   depth.
    /// - `"<prefix>/*"` matches exactly one path component under `<prefix>`.
    /// - Anything else (including a bare name with no wildcard, e.g.
    ///   `"Sources"`) is matched by exact equality only — see the note
    ///   below.
    ///
    /// ## Bare directory names are NOT recursive
    ///
    /// A scope entry of `"Sources"`, with no trailing `/**` or `/*`, matches
    /// only a changed path that is *literally* `"Sources"` — it does **not**
    /// match `"Sources/foo.swift"`. This is deliberate, not an oversight: a
    /// glob matcher that silently treated a bare name as "this directory and
    /// everything under it" would make the scope's actual reach depend on a
    /// convention the config author has to already know, and a scope gate
    /// that is more permissive than its author expects is a security bug. A
    /// config author who writes `scope: ["Sources"]` meaning "everything
    /// under Sources" gets a hard, early `out_of_scope` rejection on the
    /// very first file inside it — not a silently-too-broad allow — and the
    /// rejection's `detail` spells out the fix (`Sources/**`). Since `init`
    /// (Task 15) is expected to always emit `Sources/**`-shaped entries, this
    /// case should be rare in practice; when it happens, failing loud and
    /// explaining is safer than guessing the author's intent.
    ///
    /// ## Case sensitivity
    ///
    /// This comparison is case-SENSITIVE on every platform, via ordinary
    /// Swift `String` equality — deliberately, even though macOS's default
    /// filesystem (APFS) is case-insensitive-but-preserving while Linux's is
    /// case-sensitive. `changedPaths` comes from `git diff --name-only`,
    /// which reports paths exactly as recorded in git's tree objects —
    /// case-sensitive, byte-exact, and identical on every platform
    /// regardless of the host filesystem's own folding behaviour. Matching
    /// case-insensitively here would make the gate's permissiveness depend
    /// on which OS it happens to run on, and would risk exactly the failure
    /// this gate exists to prevent: a path that differs from an in-scope
    /// directory only by case (for instance a helper target directory that
    /// must stay out of scope) being waved through because it "looks like"
    /// the same name. A case-sensitive, git-native comparison behaves
    /// identically everywhere and never over-matches.
    ///
    /// ## Unicode normalisation
    ///
    /// This comparison does NOT force any particular normalisation form —
    /// it uses Swift's default `String` comparison operators (`==`,
    /// `hasPrefix`), which compare by canonical equivalence (an NFC-encoded
    /// and an NFD-encoded spelling of the same filename compare equal).
    /// That is intentional and matches how `FrozenSnapshot`'s manifest
    /// (a `[String: String]` keyed by path) already compares paths
    /// elsewhere in this codebase — both types trust Swift's grapheme-aware
    /// String equality rather than fighting it with raw UTF-8 byte
    /// comparison. Canonical equivalence only equates strings that denote
    /// the *same* sequence of Unicode scalars a human would consider the
    /// same filename; it does not fold distinct filenames together, so it
    /// introduces no over-matching risk. The alternative — comparing raw
    /// UTF-8 bytes — would instead risk spurious `out_of_scope` rejections
    /// whenever a path arrives in a different normalisation form than the
    /// one the scope glob happened to be typed in, which is a real
    /// possibility given `changedPaths` now returns genuine byte-exact,
    /// unescaped paths (see `Git.changedPaths`).
    public static func matches(_ path: String, glob: String) -> Bool {
        if glob == "**" { return true }
        if glob.hasSuffix("/**") {
            let prefix = String(glob.dropLast(2))
            return path.hasPrefix(prefix)
        }
        if glob.hasSuffix("/*") {
            let prefix = String(glob.dropLast(1))
            guard path.hasPrefix(prefix) else { return false }
            return !path.dropFirst(prefix.count).contains("/")
        }
        return path == glob
    }

    /// Checks every changed path against `scope`, throwing the first
    /// failure found.
    ///
    /// Manifest paths are checked first and unconditionally — before the
    /// scope loop even starts — so a `Package.swift` edit is always reported
    /// as `manifest_change_rejected`, never as merely `out_of_scope` (which
    /// would imply that widening `scope` could fix it; it cannot).
    ///
    /// An empty `changedPaths` has nothing to iterate over in either loop,
    /// so it passes trivially — a no-op change is not a scope violation.
    public static func check(changedPaths: [String], scope: [String]) throws {
        for path in changedPaths where manifestPaths.contains(path) {
            throw GateFailure(
                reason: "manifest_change_rejected",
                detail: """
                \(path) was modified. This is rejected regardless of scope. Package.swift is \
                the dependency list, the build-flag surface (swiftSettings, unsafeFlags, \
                -Ounchecked, -enforce-exclusivity=unchecked) and an executable Swift program \
                run at build time. A dependency or flag change alters what is being measured \
                rather than how fast it runs, and is a human decision, not an autonomous one.
                """)
        }
        for path in changedPaths {
            guard scope.contains(where: { matches(path, glob: $0) }) else {
                throw GateFailure(
                    reason: "out_of_scope",
                    detail: """
                    \(path) is outside the configured scope \(scope). A scope entry matches \
                    either a literal path, or a directory prefix followed by /** (any depth \
                    under that directory) or /* (exactly one level under it) — a bare directory \
                    name with no wildcard, e.g. "Sources", matches only a file literally named \
                    that, not anything inside it.
                    """)
            }
        }
    }
}
