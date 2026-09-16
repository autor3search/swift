// Sources/AutoR3SearchKit/Templates/ProgramMD.swift
//
// `program.md` is the instructions an AI agent reads before it starts
// optimizing a repository. It is written once by `init` and the agent is
// told never to edit it. Two facts verified against a real toolchain on this
// machine shape its content and must never regress:
//
//   1. The benchmark package was renamed: `https://github.com/ordo-one/benchmark`
//      (product/package identifier `benchmark`), not the old
//      `ordo-one/package-benchmark` URL, which still resolves today but emits a
//      deprecation warning. Emitting the old URL here would put stale advice in
//      front of every agent that reads this file.
//   2. The documented `let benchmarks = { ... }` idiom does NOT compile under
//      Swift 6 language mode (`let 'benchmarks' is not concurrency-safe`). The
//      working form is `nonisolated(unsafe) let benchmarks = { ... }`. An agent
//      that copies a non-compiling snippet from our own docs will not trust the
//      rest of this file.
import Foundation

public enum ProgramMD {
    public static func render(config: Config, tag: String) -> String {
        """
        # program.md

        You are optimizing this Swift repository. A frozen measurement harness decides
        whether each change is kept. You do not grade your own work.

        ## The loop

        1. Print a context line:
           `[exp <n> | autor3search-swift/\(tag) | stop: autor3search-swift stop]`
        2. Form ONE hypothesis about what is slow and why.
        3. Edit only files matching: \(config.scope.joined(separator: ", "))
        4. `git add -A && git commit -m "<what you changed and why>"`
        5. `autor3search-swift eval --json`
        6. Exit code 0 (KEEP): the commit stays. Anything else: `git reset --hard HEAD~1`.
        7. Next idea.

        ## What you may not do

        - Never edit program.md, .autor3search/config.yaml, results.tsv, or anything the
          harness writes. They are not yours.
        - Never edit Package.swift or Package.resolved. Any change to either is rejected
          outright, regardless of scope. This includes swiftSettings and unsafeFlags: you
          cannot win by changing compile flags instead of code.
        - Never edit test or benchmark files. They are restored before every evaluation.
        - Never pass --force to any autor3search-swift command.

        ## Reading the verdict

        - `no_significant_improvement` - nothing measurably moved. Try a different idea.
        - `improvement_below_min_effect` - it really did get faster, by less than
          \(config.minEffectPct)%. The direction was right; go bigger on the same idea.
        - `significant_regression` - you sped one thing up by harming another.

        `autor3search-swift profile` gives real profiler data on where time actually goes,
        so you do not have to guess at hot paths.

        ## Benchmarks in this repository

        \(config.benchmarks.map { "- \($0)" }.joined(separator: "\n"))

        Benchmarks are defined with https://github.com/ordo-one/benchmark, in the
        `\(config.benchmarkTarget)` target, using the form:

            nonisolated(unsafe) let benchmarks = { ... }

        ## Stopping

        The human stops you by running `autor3search-swift stop`. You will see it as
        `"stop_requested": true` in a verdict. When you do: apply that verdict, do not
        start another experiment, run `autor3search-swift report`, summarize, and exit.
        """
    }
}
