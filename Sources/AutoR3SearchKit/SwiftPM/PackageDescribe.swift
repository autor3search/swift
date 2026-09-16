import Foundation

/// One target as reported by `swift package describe --type json`.
public struct SwiftTarget: Equatable, Sendable {
    public let name: String
    public let type: String
    public let path: String
    public let productDependencies: [String]

    public init(name: String, type: String, path: String, productDependencies: [String]) {
        self.name = name
        self.type = type
        self.path = path
        self.productDependencies = productDependencies
    }
}

/// The parsed output of `swift package describe --type json`.
public struct PackageDescription: Sendable {
    public let targets: [SwiftTarget]

    public init(targets: [SwiftTarget]) {
        self.targets = targets
    }

    public var testTargets: [SwiftTarget] { targets.filter { $0.type == "test" } }

    /// The benchmark package's targets are executables carrying the Benchmark product
    /// (spec.md 2.4). They do NOT have `type == "test"`, so `testTargets` alone would
    /// miss them; identification is by product dependency, not target type.
    public var benchmarkTargets: [SwiftTarget] {
        targets.filter { $0.productDependencies.contains("Benchmark") }
    }

    /// Everything the agent must not be able to rewrite: tests AND benchmarks.
    ///
    /// May be empty (a package with no test targets and no benchmark targets) — this
    /// layer reports what it found without judgment. Whether an empty freeze set is
    /// acceptable is a policy question for the caller that later hard-fails on an
    /// empty manifest, not something to paper over silently here.
    public var frozenDirectories: [String] {
        (testTargets + benchmarkTargets).map(\.path)
    }
}

public enum PackageDescribeError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self {
        case .failed(let message): return "swift package describe failed: \(message)"
        }
    }
}

public enum PackageDescribe {
    private struct Raw: Decodable {
        struct Target: Decodable {
            let name: String
            let type: String
            let path: String
            // Optional: a plain library target's JSON may omit this key entirely
            // rather than reporting an empty array, so decoding must tolerate its
            // absence instead of failing the whole parse.
            let product_dependencies: [String]?
        }
        let targets: [Target]
    }

    public static func parse(_ json: Data) throws -> PackageDescription {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: json)
        } catch {
            throw PackageDescribeError.failed("could not decode swift package describe output: \(error)")
        }
        return PackageDescription(targets: raw.targets.map {
            SwiftTarget(name: $0.name, type: $0.type, path: $0.path,
                        productDependencies: $0.product_dependencies ?? [])
        })
    }

    /// Runs `swift package describe --type json` in `repo` and parses its output.
    ///
    /// The command can print warnings to stdout before the JSON object; scanning for
    /// the first `{` skips them. Empirically (see the written report), a manifest's
    /// own `print()` output is rerouted by SwiftPM to stderr as a `warning:` line, so
    /// in practice stdout carries JSON only — but the scan is a defensive fallback in
    /// case that ever changes, not something relied on to filter arbitrary noise.
    ///
    /// `outputTruncated` IS checked explicitly here, ahead of parsing. A truncated
    /// capture would almost always fail `JSONDecoder` anyway (an unterminated object
    /// is not valid JSON), which is already loud — but failing on the flag directly
    /// gives an unambiguous diagnosis instead of a decoder error that could be
    /// mistaken for a malformed manifest. Silently paring down the *freeze set* would
    /// be far worse than either kind of loud failure, so both paths refuse rather
    /// than guess.
    public static func describe(repo: URL, timeout: TimeInterval = 300) throws -> PackageDescription {
        let swift = URL(fileURLWithPath: "/usr/bin/swift")
        let r = try Subprocess.run(swift, ["package", "describe", "--type", "json"],
                                    cwd: repo, env: nil, timeout: timeout)
        guard r.exitCode == 0 else { throw PackageDescribeError.failed(r.stderr) }
        guard !r.outputTruncated else {
            throw PackageDescribeError.failed("swift package describe output was truncated at the capture cap")
        }
        // The command may print warnings before the JSON; start at the first brace.
        guard let start = r.stdout.firstIndex(of: "{") else {
            throw PackageDescribeError.failed("no JSON in output")
        }
        return try parse(Data(r.stdout[start...].utf8))
    }
}
