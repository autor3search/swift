# autor3search-swift

[autoresearch for your codebase](https://autor3search.dev/) — the same loop in eight languages, with every agent prompt in one place.

**Autonomous AI-driven performance optimization for any Swift package.**

Point your coding agent at your repo and go to sleep. It proposes an optimization,
runs it through a frozen measurement harness, and the harness decides: **KEEP** or
**DISCARD**. You wake up to a log of experiments and faster code.

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch), which
does this for a single-GPU LLM training loop. This does it for Swift — where the
metric is wall-clock nanoseconds instead of `val_bpb`, and where **correctness is
not optional**.

> **Status: early, working, and narrower than it looks.** Validated end to end
> against its own `DemoPackage` fixture: a real optimization is kept, a
> comment-only commit is discarded, and every cheat route in
> [What the harness enforces](#what-the-harness-enforces) was run as a live attack
> against a real release binary. Every number in this README and in
> [SECURITY.md](SECURITY.md) is a real measurement, never an illustration.
>
> **It has now found a win on a third-party repository — once, on a local clone,
> and the caveats are the point.** A full loop against `apple/swift-asn1`
> (benchmarks in the nested package layout the ecosystem actually uses) ran **11
> experiments: 9 KEEP, 2 DISCARD, cumulative ratio 0.0910 — 10.98× faster** on
> its PEM parsing, with **all 118 of the library's own tests passing** at the end.
> Read the rest of this block before quoting that number.
>
> - **This was a local clone. Nothing was contributed upstream** — no remote, no
>   PR, no patch sent. `swift-asn1` is not faster for anyone who uses it.
> - **10.98× is the product of the per-experiment ratios, and that is the figure
>   to quote.** Absolute medians drifted by up to **8%** between evals on the same
>   commit, so each ratio is internally valid — the harness re-measures both sides
>   inside every eval — but the µs chain behind it is a series of
>   separately-anchored measurements, not one continuous one.
> - **The win is raw pointer arithmetic**, flagged by the harness at **13 unsafe
>   sites** at HEAD, with its own warning that frozen tests verify behaviour but
>   cannot catch undefined behaviour. It needs a human review of the bounds
>   reasoning, and ideally a fuzz run over malformed PEM, before anyone would
>   merge it.
> - **9 of 11 is not the expected hit rate**, and saying so matters more than the
>   headline. `PEMDocument.swift` was idiomatic Swift over `Substring.UTF8View` —
>   correct, readable, and accidentally very slow; the first two experiments
>   recovered **4.7×** by moving the same algorithm onto raw bytes. That is one
>   unusually large piece of headroom. Experiments 10 and 11 were two perfectly
>   reasonable ideas that moved the benchmark by **0.06%** and **0.08%**, and that
>   is what the effect floor normally does.
> - **The profile contradicted expectation**, which is the single most interesting
>   thing in the run: base64 decoding was **6%** of the time, while
>   `Collection.firstIndex(of:)` over `Substring.UTF8View` was **63%** — its
>   `Index` is a `String.Index`, so every element access goes through scalar
>   alignment.
>
> The full transcript — every ratio, every p-value, and the run's own list of
> concerns — is in this project's run log.

```
agent commits one change
        │
        ▼
autor3search-swift eval
        │
        ├── exit 0  KEEP     → the commit stays, and the measurement point moves to it
        └── anything else    → git reset --hard HEAD~1
```

That is the whole loop. Everything below is about making the KEEP trustworthy.

---

## Start here

Open your coding agent inside the Swift package you want to make faster, and
paste this:

```text
You are optimizing this Swift repository for performance.

Setup (once):
1. brew install autor3search/tap/autor3search-swift
   (or build from source — see its README.)
2. autor3search-swift init
   Show me the benchmarks it discovered. If it reports none, STOP and tell me:
   this tool can only optimize what it can measure.
   Read its scope warning. If any listed target is fixture data rather than code
   under test, tell me before going further.
3. git add .autor3search/config.yaml program.md && git commit -m "harness config"
4. autor3search-swift doctor
   Show me any warnings. If the machine looks unfit to measure, stop and ask me.
5. autor3search-swift baseline --tag <today, e.g. sep18>

Then:
6. Read program.md in this repository, in full. It is your instruction set for
   the rest of this run. Follow it exactly.

Rules for the whole run:
- Never edit program.md, .autor3search/config.yaml, Package.swift,
  Package.resolved, results.tsv, or any test or benchmark file. They are not yours.
- Never pass --force to any autor3search-swift command. (I may run
  `autor3search-swift stop --force` myself; that one is mine, not yours.)
- One idea per experiment. Commit before each eval.
- KEEP means the commit stays. Anything else means git reset --hard HEAD~1.
- Print one context line before each experiment:
  [exp <n> | <branch> | vs <measurementCommit> | stop: autor3search-swift stop]

Run the loop until I stop you. I stop you by running `autor3search-swift stop` in
my own terminal — you will see it as "stop_requested": true in a verdict. When you
do: apply that verdict, do not start another experiment, run
`autor3search-swift report`, summarize what you tried, and exit the loop.
```

That's the whole handoff. `init` writes `program.md` into the repository with the
loop already filled in for *your* package — the real scope globs, the real
benchmark names, the real stop command.

What you get back: one commit per accepted change on a branch named
`autor3search-swift/<tag>`, and a `results.tsv` recording every experiment that
was tried, including the ones that failed. `autor3search-swift report` summarizes
it.

Two things worth knowing before you start:

- **It needs benchmarks.** The tool optimizes what it can measure, and refuses to
  guess. See [Repos with no benchmarks](#repos-with-no-benchmarks).
- **Numbers are only as good as the machine.** Run `doctor` and read it. A
  thermally throttled laptop on battery produces noise dressed as data.

## Install

```sh
brew install autor3search/tap/autor3search-swift
```

That resolves through [`autor3search/homebrew-tap`](https://github.com/autor3search/homebrew-tap)
to the tagged [v0.1.0 release](https://github.com/autor3search/swift/releases/tag/v0.1.0).
The formula's `sha256` was computed from that tarball and verified by `brew fetch`
before this line was written, so the download is checked rather than trusted.

One wrinkle, stated so it does not look like an oversight later: the copy of the
formula inside the `v0.1.0` tarball still carries the pre-release placeholder
hash, because the tag was cut before a hash could exist. The tap and `main` carry
the real one. Install through the tap, not from the tag's copy of the formula.

Or build from source:

```sh
git clone https://github.com/autor3search/swift.git autor3search-swift
cd autor3search-swift
swift build -c release
cp .build/release/autor3search-swift /usr/local/bin/
```

Requires Swift 6.0 or newer (`swift-tools-version: 6.0`). Developed and measured
on Swift 6.4 / macOS 26.6.2. See [Limitations](#limitations) for what is verified
where — Linux is correctness-verified only, and no Linux timing exists.

## The idea

You do not edit Swift files to tune performance. You edit `program.md` — the
instructions that drive your agent. The agent edits the Swift. A compiled harness
holds the metric, and the agent cannot reach it.

| Piece | What it is | Who edits it |
|---|---|---|
| `autor3search-swift` | the harness binary: gates, measures, scores | nobody — it's compiled |
| your test and benchmark targets | frozen at baseline, restored before every run | nobody — restored automatically |
| your Swift source | whatever is in `scope` | **the agent** |
| `program.md` | the agent's standing brief | **you** |
| `Package.swift`, `Package.resolved` | the build and the dependency set | **you**, once — any change is rejected outright |
| `.autor3search/config.yaml` | the run configuration | **you**, once — hashed at baseline |
| frozen snapshot, baseline record, pinned worktree, run claim | lives outside your repo, under the OS cache directory (or `AUTOR3SEARCH_SWIFT_STATE_HOME`) | nobody |

That last row matters: the agent edits the repository, so anything the score
depends on that *lived* there would be silently writable by the very agent it is
meant to constrain. The only harness output that stays inside your repo is
`results.tsv` (a human-readable log, not part of the metric) and `run.log` —
both gitignored by `init`.

Moving that state out of the repository puts it outside the *scope gate*. It does
not put it out of reach: these are plain files owned by the same user as the
agent. See [Security](#security).

## Quick start

```sh
cd your-swift-package
autor3search-swift init                                   # find benchmarks, write config + program.md
git add .autor3search/config.yaml program.md && git commit -m "harness config"
autor3search-swift doctor                                 # is this machine fit to measure?
autor3search-swift baseline --tag sep18                   # freeze tests, pin the baseline commit
```

**`init` makes a commit in your repository.** It commits exactly `.gitignore` and
`Package.resolved` — and only whichever is untracked or modified. It stages *by
path*, never `git add -A`, prints the SHA and the paths, and prints
`git reset --soft HEAD~1` to undo. It does **not** commit `config.yaml` or
`program.md`: read those first, then commit them yourself.

The reason is unglamorous and load-bearing. `swift package describe` does not
write `Package.resolved`, but `swift build` does, into the package root. A
repository without a committed lockfile has its *first* `eval` create one — and
every experiment after that fails permanently, as `manifest_change_rejected` if
the agent commits it or `dirty_working_tree` if it does not.

`init` also prints a **scope warning** naming every target the benchmark depends
on directly. SwiftPM's manifest cannot distinguish "code under test" from
"fixture data the benchmark consumes", so nothing is excluded automatically. If
any listed target is input data, remove it from `scope` before `baseline` — an
agent that can shrink a benchmark's input can win without making anything faster.

The config `init` writes, verbatim:

```yaml
version: 1
scope:
- Sources/Demo/**
benchmarks:
- CountWords
count: 10
alpha: 5e-3
benchmark_target: Bench
min_effect_pct: 3e+0
max_regress_pct: 3e+0
timeout_seconds: 600
# Delete every compiled artifact under .build before each side is built, so the
# measured binaries come only from sources the gates hashed. OFF by default: it
# roughly doubles the cost of an experiment (measured +33.6s on the demo package).
# Dependencies are not re-resolved either way -- this is a cold build, not a
# re-clone. See "The build cache is not verified" in the README.
purge_build_output: false
```

| Key | Default | Meaning |
|---|---|---|
| `scope` | derived | Glob list; a commit touching anything outside it is rejected before anything is built. An entry is a literal path, `<prefix>/**` (any depth under it), or `<prefix>/*` (exactly one component). The trailing slash is required, so bare `Sources` does **not** match `Sources/**` — under-matching, deliberately. |
| `benchmark_target` | derived | The one executable target that depends on the `Benchmark` product. |
| `benchmarks` | derived | The benchmark names to measure. |
| `count` | `10` | Rounds per side, interleaved B, C, B, C, … Raising it is the intuitive response to a noisy verdict and the wrong one — see [Limitations](#limitations). |
| `alpha` | `0.005` | Significance level. |
| `min_effect_pct` | `3.0` | A win must be at least this large. |
| `max_regress_pct` | `3.0` | A benchmark regressing beyond this, significantly, is an outright refusal. Equal to `min_effect_pct` on purpose. |
| `timeout_seconds` | `600` | Per build / test / measurement step. |
| `purge_build_output` | `false` | Delete every compiled artifact under `.build` **before** each side is built. It addresses a *stale* poisoned artifact left by a previous eval; it does **not** address one written *during* one — see [SECURITY.md](SECURITY.md#the-build-cache-is-not-verified). Off because it costs a measured **+33.6 s** per eval. Optional in the file: a config written before this key existed still loads, and still matches the SHA-256 `baseline` pinned. |
| `benchmark_package_path` | *absent* | The directory of the SwiftPM package that declares `benchmark_target`, relative to the repository root — see [Benchmarks in a nested package](#benchmarks-in-a-nested-package). **Omit it entirely for benchmarks in the root package**; absence is what every config written before this key existed means, and a config without it hashes to exactly what `baseline` pinned. An empty string is *not* a second spelling of absent, and is refused. |

### Benchmarks in a nested package

**The layout every real adopter uses.** `ordo-one/package-benchmark`'s
convention is a second SwiftPM package at `Benchmarks/Package.swift` declaring
`.package(path: "../")` plus the benchmark dependency, with the benchmark
target's sources at `Benchmarks/Benchmarks/<Target>/`. Of the repositories
surveyed for this feature — `apple/swift-asn1`, `apple/swift-log`,
`GraphQLSwift/GraphQL`, `CoreOffice/XMLCoder` — **all four are laid out that way
and none has a benchmark target in its root package.**

`init` auto-detects exactly one location, `Benchmarks/`, and writes the key when
it finds benchmarks there. It does not go hunting for nested `Package.swift`
files anywhere else: a repository can contain several (vendored dependencies,
sample projects, a test fixture), and picking one of them by a heuristic is the
kind of silent guess `init` refuses to make elsewhere. An unconventional location
is configured by hand. If **both** packages declare benchmark targets, the root
wins — that is the no-change branch for every repository configured before this
key existed — and `init` names the other candidate so you can switch by hand.

What `init` wrote for `apple/swift-asn1`, appended to the config above, verbatim:

```yaml
# The directory of the SwiftPM package that declares benchmark_target, relative to
# the repository root. Omit it entirely for benchmarks in the root package -- that
# is what every config written before this key existed means. The benchmark target
# and BenchmarkTool are built from this package and measured out of
# <path>/.build/release/; `swift test` still runs at the repository root, because
# the library's tests are the correctness contract and they live there.
benchmark_package_path: Benchmarks
```

A nested package brings a **second `.build`, a second `Package.resolved`, a
second `.build/checkouts` and a second `.build/plugins`** into the repository
under test, and every one of those is compiled into — or executed during — the
measured build. The gate chain covers all of them; see
[The gate chain](#the-gate-chain) and
[SECURITY.md](SECURITY.md#the-nested-benchmark-package-doubles-every-tree-that-matters).

Two things to know before you point it at a nested-layout repository:

- **The clone's directory name is load-bearing.** SwiftPM derives a path
  dependency's identity from the directory name, so `Benchmarks/Package.swift`'s
  `package: "swift-asn1"` only resolves if the checkout really is called
  `swift-asn1`. A clone named anything else fails with `unknown package`.
- **A bare `Package.resolved` line in `.gitignore` matches at any depth**, so it
  hides the nested lockfile as well as the root one. `init` refuses that up
  front and names the remedy (delete the line, or add `!Benchmarks/Package.resolved`).
  `baseline` refuses it too, for both packages.

### Why the defaults are stricter than convention

`alpha` is **0.005**, not `0.05`. For a single-benchmark package `k = 1`, so the
Bonferroni-corrected `alpha/k` is *numerically identical* to the uncorrected one —
the "corrected" bar in the default configuration is not corrected at all, and a
bare `0.05` was measured failing to separate two separately compiled binaries (the
one spurious KEEP in 100 no-op trials came in at `p = 0.03546`). The tightening is
close to free: at `count: 10` the p-value floor is `2/C(20,10) = 1.0825e-5`, so
`alpha/k` still admits **461** simultaneous benchmarks before a KEEP becomes
unreachable at all.

`min_effect_pct` is **3.0**, not `1.0`, because a floor the noise can step over is
not a floor: on *identical code* the measured excursion from ratio 1.0 reached
**1.39%** at ~3.6 ms per iteration and **3.215%** at ~54 µs. `max_regress_pct` is
**3.0** and equal to it deliberately — **no single benchmark may be harmed by more
than the aggregate win the change is required to demonstrate**; at the old
`1.0 / 5.0` a change could significantly regress a benchmark by 4.9% on the
strength of a 1.0% win. `count` stayed at **10**: raising it makes a drifting no-op
read *more* significant, not less.

## Watching a run, and stopping it

The agent's loop calls `eval --json`, which by contract prints one JSON object
and nothing else. Ask the run where it is instead, from any terminal, any branch:

```
$ autor3search-swift status --tag readme
Status for tag "readme"
  run directory:       ~/Library/Caches/autor3search-swift/fbff97c237a80426/readme
  frozen commit:       0662f59e4394c728b359a4dd29f75c3e030f0fa4
  measurement commit:  3b1dbc9076435c4f43b1fdaa014a0910cc4f5876
  repo HEAD:           585e9c279e359834e4e4d1fe34d54ef5b07714a2 (branch autor3search-swift/readme)
  eval in flight:      no
  stop requested:      no
  experiments logged:  2 (keep 1, discard 1, fail 0, crash 0)
```

Read those two commit lines together: `frozen commit` has not moved and
`measurement commit` has. That split is the whole design — see
[Scoring](#scoring).

There are three ways to stop a run:

1. **`autor3search-swift stop --tag <tag>`** — the polite one, and the one to
   use. It writes a request the running `eval` reports back as
   `"stop_requested": true`. The agent finishes the experiment it is on, applies
   that verdict, and exits the loop. `--clear` cancels a pending request.
2. **`stop --force`** — additionally signals a running `eval` on this host to
   abandon the current experiment, and reports what state that leaves the
   repository in.
3. **Ctrl-C** in the terminal running `eval`.

## Commands

| Command | What it does |
|---|---|
| `init` | Discovers benchmark and test targets via `swift package describe --type json` — in the root package and in a nested `Benchmarks/` package, writing `benchmark_package_path` when it finds them there — discovers benchmark names by parsing `Benchmark("Name")` literals, writes `.autor3search/config.yaml` + `program.md` + `.gitignore` entries, and commits the lockfile and `.gitignore`. Refuses a repository with no benchmarks, one with more than one benchmark target, and one whose `Package.resolved` is gitignored. `--force` overwrites an existing config. |
| `doctor` | Checks whether this machine can measure reliably — Low Power Mode, power source, core counts, load average, disk space, XCTest availability, working-tree cleanliness, conditionally-gated tests, redeclared comparison operators, the dependency pin — and builds the measurement products by name. Informational; always exits 0. `--skip-build` skips the build probe. |
| `baseline --tag <tag>` | Creates the run branch `autor3search-swift/<tag>`, freezes every file in every declared test and benchmark target, records the manifest and out-of-scope inventories, and pins a detached worktree at the baseline commit. Refuses a dirty tree and a reused tag. |
| `eval` | Runs one experiment through the gate chain, measures, scores, appends a `results.tsv` row, and exits `0`/`1`/`2`/`3` for KEEP/DISCARD/FAIL/CRASH. On KEEP it advances the measurement point to the candidate's commit. `--json` prints one JSON object and nothing else. |
| `status` | Prints where a run is, read-only. Accepts `--tag <tag>` so it works from any branch. |
| `stop` | Asks the run to end after the current experiment. `--clear` cancels; `--force` signals a running `eval`. |
| `report` | Counts by status, cumulative speedup as the product of every kept score, the largest individual wins, and which kept commits introduced unsafe constructs. |
| `profile` | Hot source lines from `sample` (macOS) or `perf` (Linux, where permitted), plus a per-benchmark instruction and malloc-count table. Builds and measures out of the package `benchmark_package_path` names, exactly as `eval` does. Refuses loudly where no sampler is permitted rather than reporting nothing. `--benchmark <name>`, `--seconds <n>` (default 5). |
| `version` | The module version for an installed binary, or the commit for one built from a checkout, marked `dirty` when the tree had uncommitted changes. |

Every command accepts `-C <dir>` to run against a repository other than the
current directory.

Exit codes: **0 KEEP**, **1 DISCARD**, **2 FAIL** (a gate rejected; nothing was
measured), **3 CRASH** (the harness itself failed). FAIL and CRASH are not
DISCARDs: a run that produced no verdict is not a correct rejection, and the
agent's loop should treat them as "something is wrong with the setup", not "that
idea did not work".

`eval --json`'s `reason` is a stable, machine-readable string. The gate table
below names every one it can emit, plus `run_already_in_progress` and
`run_tainted`.

### Where run state lives

Everything the metric depends on — the frozen snapshot, the baseline record, the
pinned worktree, the run claim — is kept **out of the repository**, under
`~/Library/Caches/autor3search-swift/<repo hash>/<tag>/`:

```
baseline.json           the two commits, the config hash, the manifest inventory
frozen/                 byte-for-byte copies of every frozen test and benchmark file
frozen-manifest.json    what "frozen" covered
baseline-worktree/<repo>  a detached worktree pinned at the measurement commit
run.claim               an flock'd file: one eval per run at a time
```

The pinned tree sits one level down, inside a directory named after the
repository, and that nesting is load-bearing rather than tidy. SwiftPM derives a
path dependency's identity from its directory name, so a nested benchmark
package's `.package(path: "../")` used to resolve to the identity
`baseline-worktree` and could not satisfy `package: "swift-asn1"`. **The
baseline side of every nested-layout repository was unbuildable**, and no
configuration change could have fixed it, because the offending name was the
harness's own. A run baselined under the older layout is refused with
`baseline_predates_worktree_layout`, which names the remedy — re-baseline under
a new tag — rather than failing to restore a tree that is not there.

Set `AUTOR3SEARCH_SWIFT_STATE_HOME` to an absolute path to put it elsewhere. A
relative value is refused: it would resolve against whatever directory each
command happened to run from, so `eval` from a subdirectory and `stop` from the
repository root would address different state for the same run.

## The gate chain

`eval` runs these in order. Gates 1 through 4 reject before anything is built or
measured — a FAIL from them costs seconds, not minutes.

| # | Gate | Rejects with |
|---|---|---|
| 1 | **Scope.** Every path changed between `frozenCommit` and `HEAD` must match a `scope` glob. Any change to `Package.swift` or `Package.resolved` is rejected outright, regardless of scope. | `out_of_scope`, `manifest_change_rejected` |
| 2 | **Config integrity.** SHA-256 of `.autor3search/config.yaml` must equal what `baseline` recorded. | `config_hash_mismatch` |
| 2a | **Manifest integrity, by hash.** Every manifest *as it is on disk*, including a nested benchmark package's `Package.swift` and `Package.resolved` and anything under `.swiftpm/` — and a manifest *appearing* where baseline recorded none is itself a mismatch. | `manifest_change_rejected` |
| 2b | **Clean working tree**, read with `git status --porcelain --ignored`. Ignored files are recorded at baseline, not banned: only one that appears, changes or disappears after the freeze is refused. Tracked files are additionally hashed against the commit's blob ids, because a `filter.<name>.clean` driver can make `git status` report a modified file as clean. | `dirty_working_tree` |
| 2c | **Out-of-scope files, by content.** Hashes every file outside `scope` except `.git/`, `.build/` and the harness's own outputs. Gate 1 asks git what changed; 2c asks the disk. | `out_of_scope` |
| 2d | **Dependency checkouts, both sides, both packages.** Every file under `.build/checkouts/`, verified per dependency against the revisions `Package.resolved` pins — in the repository *and* in the pinned worktree, for the root package *and* for the nested benchmark package. The nested one is the tree that supplies `BenchmarkTool` and the build-tool plugin, and on `apple/swift-asn1` it is **805 files against the root package's 0**. | `dependency_checkout_modified` |
| 3 | **Restore frozen files**, after the whole stored manifest is verified against the recorded hashes. The freeze set is the union over both packages, so a nested benchmark target's sources at `Benchmarks/Benchmarks/<Target>/` are frozen exactly as a root one's are. Symlinks are refused at snapshot and at restore time. | `frozen_restore_refused` |
| 4 | **Reject new files** appearing in any frozen target directory. | `new_test_or_benchmark_file` |
| 4b | **Discard caches no inventory can vouch for.** `.build/plugins` is deleted before every build, on both sides and in **both** packages, always — with a nested package the copy that actually executes is the nested one, because that is the package the benchmark is built from. | `plugin_cache_not_purged`, `build_output_not_purged` |
| 5 | **Release build**, then the candidate's measured binaries are hashed. The bare `swift build` stays at the repository root (that library is what `swift test` exercises); the benchmark target and `BenchmarkTool` are built from — and measured out of — `<benchmark_package_path>/.build/release/`. | `build_failed`, `build_timed_out` |
| 6 | **Tests.** `swift test` — which builds and runs in **debug**, while everything measured is **release**. | `tests_failed`, `tests_timed_out` |
| 6b | **Re-validate everything gate 6 could have changed**, because `swift test` is the agent's code. Re-runs every read-only check above and re-purges the plugin cache. | `head_moved_during_eval`, and the reasons of every gate it repeats |
| 7 | **Worktree integrity.** Restores the pinned worktree unconditionally, clearing index flags first, then verifies contents by hashing against the commit's blob ids rather than asking `git status`. | `worktree_integrity` |
| 8 | **Measure.** Interleaved, `count` rounds per side, one discarded warm-up per side. All four measured binaries are re-hashed before every sample. | `measured_binary_changed` |
| 8b | **HEAD again**, because the measurement runs the agent's benchmark. | `head_moved_during_eval` |
| 9 | **Score.** The three-part rule below. | `no_significant_improvement`, `improvement_below_min_effect`, `significant_regression` |

Gates 2a–2d exist because **git's view of a repository is not the disk, and the
adversary owns git's view**. Gate 1 derives what changed from
`git diff --name-only`; `swift build` compiles what is on the filesystem. The
path-based checks are a first-line filter; the boundary is content. A hash cannot
be talked out of noticing.

## Worked example

`Fixtures/DemoPackage` is a real SwiftPM package with a real
[`ordo-one/benchmark`](https://github.com/ordo-one/benchmark) dependency. Its
`countWords` builds each word with `word = word + String(Character(ch.lowercased()))`
— a fresh `String` allocation per character. The candidate replaces it with one
reserved `[UInt8]` buffer and a single pass over `s.utf8`, falling back to the
exact general implementation the moment a byte `>= 0x80` appears.

All numbers below were measured on **MacBook Pro `Mac17,2`, Apple M5, 10 cores
(4 performance + 6 efficiency), 32 GB, macOS 26.6.2, Swift 6.4, on AC, Low Power
Mode off.**

**Experiment 1 — a real optimization:**

```
$ autor3search-swift eval
  CountWords  3592191 -> 422911 ns  ratio 0.1177  p=0.00001
measured from a release build
VERDICT: KEEP                                                   # exit 0
```

**Experiment 2 — a commit that adds one comment line and nothing else:**

```
$ autor3search-swift eval --json                                # exit 1
{"alpha":0.05,"benchmarks":[{"baselineMedian":423935,"benchmark":"CountWords",
"candidateMedian":420863,"pValue":0.07525601333650869,"ratio":0.9927536060952741,
"significantAtAlpha":false,"significantAtCorrected":false}],"build_configuration":"release",
"corrected_alpha":0.05,"exit_code":1,"k":1,"reason":"no_significant_improvement",
"score":0.9927536060952741,"stop_requested":false,"unsafe":[],"verdict":"discard","warnings":[]}
```

The number to read is **`baselineMedian: 423935`**. Experiment 1's baseline was
3 592 191 ns. Experiment 2's is 423 935 ns — the measurement point moved by 8.5×,
because experiment 1 was kept. Had it not moved, this no-op would have been scored
against 3.59 ms, come out at roughly 0.118, and taken a second, entirely unearned
KEEP.

**Both transcripts were captured at the previous defaults** (`alpha: 0.05`,
`min_effect_pct: 1.0`), which is why the JSON reads `"alpha":0.05`. They are
reproduced unedited rather than rewritten, because the numbers in them were
measured and a retouched transcript is not. Under the shipped defaults both
verdicts are the same and the margins are wider. Note that `corrected_alpha`
equals `alpha` — `k = 1`, so Bonferroni divides by one. That is the observation
that drove the alpha change.

`autor3search-swift report` then summarises the pair: 2 experiments, 1 keep, 1
discard, **cumulative speedup 0.1177 of original duration (8.50× faster)** — the
product of every kept score, so successive real improvements compound.

### Why a rank test

Thirty independent invocations of an *unchanged* benchmark on a quiet machine,
p50 wall-clock in nanoseconds, sorted:

```
25007 25263 25263 25263 25263 25263 25263 25295 25295 25295
25295 25295 25295 25295 25295 25295 25295 25295 25343 25375
25375 25375 25375 25423 25583 25679 25759 26175 27215 43679
```

n = 30, median 25 295 ns, CV 12.88%. Twenty-nine of thirty lie between 25 007 and
27 215 ns; **one lands at 43 679 ns, 73% above the median**, and that single
outlier accounts for essentially all of the CV. A mean/variance test would be
materially distorted by it; Mann-Whitney takes it as one rank, identically whether
it is 73% or 7300% high. It is also why the two sides are **interleaved**
(B, C, B, C, …): an un-interleaved comparison cannot tell such an outlier apart
from a real change.

## What the harness enforces

An agent optimizing your code can "win" by cheating. Each route is closed, and
each was run as a live attack against a real release binary:

| Cheat | Why it fails |
|---|---|
| Weaken or delete a frozen test | Gate 3 restores every frozen file before gate 6 runs the suite; gate 1 usually rejects first |
| Add a new, easier test file | Gate 4 rejects any new file in a frozen target directory |
| Rewrite the benchmark to measure less | Benchmarks are frozen alongside the tests, and the pinned worktree is restored to the commit the record names — which the HEAD check at gates 6b/8b keeps honest |
| Change compile flags instead of code | `swiftSettings` and `unsafeFlags` live in `Package.swift`; any change to it is rejected by path *and* by hash |
| Hide a manifest edit from git (`--assume-unchanged`, `--skip-worktree`) | Gate 2a hashes the bytes on disk, not the index |
| Hide a change to an out-of-scope file the same way | Gate 2c hashes every file outside `scope` |
| Plant a source file a `.gitignore` rule hides from `git status` | Gate 2b reads `--ignored`, against an inventory taken at baseline |
| Edit `.autor3search/config.yaml` — widen scope, drop a benchmark, lower `min_effect_pct` | Gate 2 compares its SHA-256 against the baseline record |
| Measure an uncommitted edit | Gate 2b, which also hashes tracked files against the commit's blob ids |
| Tamper with the stored frozen files | Gate 3 verifies the whole manifest against recorded hashes before writing a byte |
| Coast on an earlier win | The measurement point advances on KEEP — see [Scoring](#scoring) |
| Patch a dependency's source under `.build/checkouts` | Gate 2d, on both sides, re-checked at 6b |
| Commit from inside `swift test` so the advance adopts an uninspected commit | Gates 6b and 8b compare HEAD against the commit gate 1 judged |
| Swap a measured binary mid-eval | All four are hashed after their own build and re-checked before every sample |
| Make git execute a program (`core.hooksPath`, `core.fsmonitor`, a `clean` filter) | Twenty-one config keys denied on every harness git call; content hashed against blob ids rather than asked of git |
| Slow the baseline side with an injected dylib or a spawned CPU burner | Subprocesses get a filtered environment and their own session, swept after every run |

The full evidence — nineteen attacks, before-and-after measurements, and what is
still open — is in [SECURITY.md](SECURITY.md).

## Security

**Nineteen bypasses have been found across nine reviews. Seventeen are closed.**
Most of the later ones were the same defect wearing different faces:

> **A check performed before gate 6 vouches for state consumed after gate 6.**
> Gate 6 runs `swift test`, which is the agent's code by construction.

The honest summary, and the thing to weigh before trusting an unattended run:
**`eval` compiles and executes code the agent wrote, as the same user, with no
sandbox, on a filesystem containing the pinned baseline worktree and the harness's
own state.** `autor3search-swift` does not prevent that; it **detects the part that
would change a verdict** — by hashing content rather than by asking git, so the
class is caught by effect rather than by enumeration.

**Two are open and named:** thermal/frequency skew, which leaves its mark in the
silicon rather than the process table and has been **named but never measured**;
and an explicit `setsid()` call by the benchmark, which escapes the session sweep.
Neither is implied to be closed. The harness's own state files are a **separate
boundary, not defended at all** — `baseline.json` and `frozen-manifest.json` are
unauthenticated JSON owned by the same user as the agent, and no cheap fix exists
because a MAC needs a key the attacker cannot read. That remedy is operational: a
different uid, or a state root read-only to the agent's.

[**SECURITY.md**](SECURITY.md) carries all of it: every attack with its measured
before-and-after, the full enumeration of what is and is not re-checked after
gate 6, the twenty-one denied git config keys and the families that cannot be
denied, both boundaries in full, the residuals, and the admission that the denial
list will go stale.

## Scoring

One number, so nothing can be cherry-picked. A benchmark's **ratio** is
`candidateMedian / baselineMedian` — below 1.0 is faster — and the **score** is
the geometric mean of the per-benchmark ratios. Significance is an **exact
two-sided Mann-Whitney U test**, not a t-test.

KEEP requires **all three**:

1. **Big enough.** `score < 1 − min_effect_pct/100`. Statistically significant is
   not enough; the win has to be worth an unattended commit.
2. **Real enough.** At least one benchmark significant at the
   **Bonferroni-corrected** `alpha / k`, where `k` is the number of benchmarks
   actually compared — not the raw `alpha`.
3. **Harmless.** No benchmark regressing beyond `max_regress_pct` *and*
   significant at the **uncorrected** `alpha`. Rule 3 is evaluated **first**: a
   change that improves the aggregate while wrecking one benchmark is refused
   outright rather than buried under a good-looking geometric mean.

**Rule 3 keeping the uncorrected alpha looks inconsistent and is not.** Rule 2 is
about *accepting a win*, so the bar is raised: conservative. Rule 3 is about
*catching harm*, and Bonferroni only ever makes significance harder to declare —
applying it there would make real regressions *easier to miss*, unattended, exactly
where nobody is watching. Liberal about noticing damage, conservative about
claiming credit. The asymmetry is load-bearing; please do not "fix" it.

The discard reasons differ because the agent's next move does:
`no_significant_improvement` (nothing moved — try another idea),
`improvement_below_min_effect` (it did get faster, just not enough — go bigger on
the same idea), `significant_regression` (you sped one thing up by harming another
— fix that, keep the idea).

### The two commits

`baseline` records two commits, and conflating them is *the* signature bug of
this family of tools.

- **`frozenCommit` never advances.** The frozen files, the config hash, the
  manifest inventory and the scope gate all compare against it. The success
  criteria must not move while the agent works.
- **`measurementCommit` advances to the candidate's commit on every KEEP.** It is
  what "faster than" is measured against.

Collapse the two and the first real win poisons everything after it: a
comment-only commit is compared against the *original* code, looks 8× faster, and
coasts to KEEP — as does every no-op after it. The run then reports a long string
of "wins" that are one win, counted many times. **That bug shipped publicly in a
sibling port.** Both halves of the advance are load-bearing: the recorded
`measurementCommit` moves, *and* the pinned worktree is re-pointed and its release
binaries rebuilt. Advancing only the number leaves the worktree still producing the
original commit's binary — the same stale baseline, one layer down, where
`baseline.json` looks perfectly correct.

### When the measurement cannot carry the verdict

`eval` prints `WARNING:` lines above its verdict (and a `warnings` array in
`--json`) when the statistics behind a result do not support reading it at face
value. They never change the decision. The one that matters: **no KEEP is
reachable.** Mann-Whitney has a floor on the p-value it can produce — with `n`
rounds per side the smallest attainable two-sided p is `2/C(2n,n)`, however far
apart the samples are. Rule 2 divides `alpha` by `k`, so enough benchmarks push
the corrected threshold below that floor and *every* experiment discards no
matter what the agent does. `count >= 4` cannot catch this, because it does not
know how many benchmarks a run will compare; the warning names the `count` to
raise to.

Allocation and instruction counts from `profile` are **hints, never scored**.
Nothing but wall-clock decides a verdict.

## Limitations

Stated plainly, because performance tools that oversell are worse than useless:

- **A KEEP is evidence, not proof.** Any fixed significance threshold admits false
  positives by construction. Measured at the **shipped** defaults: **0 spurious
  KEEPs in 100 no-op commits**, 95% Clopper-Pearson exact CI **[0.00%, 3.62%]**,
  at ~3.58 ms/iteration, 0 FAIL, 0 CRASH. **That is not an improvement on the old
  defaults** — an earlier 100 measured 0/100 with the *same* interval, because the
  bound is a property of N, not of the thresholds. The tightening replaced an
  argument with an observation; it did not show the rate fell. And **zero observed
  is not a rate of zero**: on 100 trials the harness could still be wrong about 1
  commit in 28. Narrowing the interval to ~0.3% needs ~1000 trials, roughly 11
  hours, and that price has not been paid.
- **Measurement scale changes the answer, so state the scale.** At ~48 µs per
  iteration two builds of *identical* code drift by ±3% **systematically** — the
  sides are different binaries in different directories, and fixed per-process cost
  is a large fraction of each sample. At ~424 µs the same comparison, repeated seven
  times, gave ratios 0.9970–1.0082, smallest p 0.218. **A benchmark that is too
  small is drift-dominated**: at ~54 µs the harness produced **1 spurious KEEP in
  100**, and **that arm has not been re-run at the shipped defaults** — the most
  valuable measurement missing here. Raising `count` makes it *worse*: the drift is
  a biased estimate, and more rounds resolve a bias better, so p shrinks and a
  drifting no-op becomes *more* likely to read as a win. The fix is more work per
  iteration.
- **The two gates swapped which one binds.** At the old defaults 2 of 100 trials
  were significant *and* faster, stopped only by the 1% floor — which established
  the floor as load-bearing. At the shipped defaults **0** cleared the 3% floor and
  **0** were significant at 0.005; all 100 returned `no_significant_improvement`,
  never reaching the floor check. **Alpha now rejects first and the floor is the
  wider margin.** That is evidence about which gate binds at this scale, *not* that
  the floor is unnecessary — it is what would bind if alpha were loosened. One
  concrete instance, **n = 1**: re-scored against the old bar, trial 15 (only
  change: the line `// no-op trial 15`) measured **1.68% faster at p = 0.04326** —
  a KEEP then, a DISCARD now, failing both new gates. A demonstration, not a rate.
- **That run was not taken on an idle machine; the earlier one was.** A stuck
  `BTLEServer` held ~99% of one core through all 100 trials — the same load for
  every trial rather than some. Ratio sd 0.595% against the earlier 0.573%, largest
  excursion 1.682% against 1.39%: slightly wider, in the direction a noisier machine
  would push. **Whether that is the load or ordinary run-to-run variation is not
  determined by two runs**, and is not claimed.
- **Nothing corrects for multiplicity across the loop.** Bonferroni corrects
  *within* one eval, across `k` benchmarks; nothing corrects across evals, and an
  overnight run is hundreds. Nominally at 300 evals: `alpha 0.05` → ~15 expected
  false positives, `alpha 0.005` → ~1.5. **This is the dominant multiplicity in the
  design and it is uncorrected** — correcting it properly would mean dividing alpha
  by a number of experiments you do not know in advance, and would make a KEEP
  unreachable long before morning.
- **Gate 6 runs *your* tests, and that is the softest link.** A test conditionally
  skipped from in-scope code can be disabled without touching a frozen file — and
  worse, **a frozen test constrains behaviour only as far as the code it calls is
  honest**: in-scope code can gut a function and forge the comparison the assertion
  uses, and the test still runs, asserts and passes. `doctor` warns on skip
  constructs and on operators redeclared for standard-library operand types, but it
  is a text scan and an author who is trying can evade it. When a KEEP reports an
  implausibly large win, **read the diff, not the test.**
- **Gate 6 tests a DEBUG build; the binary measured and kept is RELEASE.** A
  release-only miscompile, or an `assert` compiled out under `-O`, passes gate 6
  untested. Not trivially fixable: `swift build -c release --build-tests` fails
  (`rc=1`, module-resolution error), and `swift test -c release` rebuilds the very
  build graph the measurement depends on.
- **The build cache is not verified.** llbuild decides what to rebuild from recorded
  input signatures, so a poisoned artifact under `.build/out` for a module whose
  sources did not change is reused. `.build/plugins` is deleted every build
  (+1.62 s, ~4%) because plugins are *executed*; `purge_build_output` deletes the
  rest at +33.6 s and covers a **stale** artifact, not one written mid-eval.
- **Some layouts are stricter than you expect, and the remedy is always to
  re-baseline under a new tag.** Gate 2c hashes every file outside `scope`
  *including gitignored ones*, so a large gitignored vendored directory is re-hashed
  every eval and any legitimate change to it is `out_of_scope`; a change to any
  nested `Package.swift` is `manifest_change_rejected`; `git submodule update` is
  `out_of_scope`. A benchmark *helper* target without the `Benchmark` product
  dependency is **not frozen** — nothing restores it, though 2c means it cannot be
  edited unnoticed. Upgrading also requires re-baselining: an old `baseline.json`
  refuses with `baseline_predates_tree_inventory` rather than skipping the check,
  because *"there is no record"* must never read as *"there is nothing to check"*.
- **An agent can stop your overnight run in one line.** Once a poisoned dependency
  checkout is detected, every later eval refuses until a human deletes it. Correct
  and safe, and still a denial of service. The consistent fix — repair rather than
  refuse, as gate 7 already does for the worktree — is **not implemented**.
- **Unsafe is reported, never rejected.** `withUnsafeMutableBufferPointer` and
  friends are the idiomatic Swift optimization; rejecting them would reject the
  wins this tool exists to find. Frozen tests verify behaviour but cannot catch
  undefined behaviour. Kept commits introducing unsafe constructs are flagged for
  human review, and acting on that flag is a human's job. There is also no lint
  step: style is not this tool's business.
- **"The whole process tree is killed" is not literally true.** `swift test` spawns
  `swiftpm-testing-helper` into its own process group, and any descendant can leave
  via `setsid()`. Every spawned child now gets its own *session*, swept after each
  run — but an explicit `setsid()` by the benchmark still escapes.
- **Laptops are noisy.** One sample in thirty landed 73% above the median on an
  otherwise quiet machine. `doctor` checks Low Power Mode, power source, core
  counts and load average for that reason; read its warnings.
- **`count` below 4 can never reach significance**, and with two or more benchmarks
  neither can 4; at the shipped `alpha: 0.005` the smallest workable count is **6**
  even with one benchmark. `eval` warns when no KEEP is reachable and names the
  count to raise to. Separately, **`init` creates a commit** — exactly `.gitignore`
  and `Package.resolved`, staged by path, announced with the SHA and an undo command.
- **A known residual TOCTOU in the frozen restore.** A refused restore is recorded
  as `frozen_restore_refused` *plus* a durable `run.tainted` marker that makes every
  later `eval` refuse until a human clears it. `eval` never retries a refused
  restore — that no-retry rule caps an attacker at roughly one attempt per run, with
  a logged alarm on every loss.
- **macOS is the measured platform; Linux is correctness-verified only.** `swift
  test` is **361 of 361** on macOS. On Linux (`swift:6.1`, aarch64, glibc 2.39) it
  builds and runs and the harness's own platform behaviour is verified, but the full
  suite — measured when it was 335 tests, and not re-run since — returns
  **`rc=1`: 328 tests, 8 issues** — 7 are the cross-platform
  `Package.resolved` lockfile refusal (a macOS lockfile cannot be `init`-ed on Linux
  or vice versa) and 1 is a genuine flake from tests sharing a SwiftPM cache under
  `HOME`. **No Linux timing exists**, deliberately: benchmarking in a VM on a Mac
  produces numbers this project would have to disown. Assume other
  macOS-only-verified tests may be weaker than they look — two were found asserting
  nothing at all on Linux. **And the macOS suite is not reliably green either**: the
  same isolation fragility surfaced there once, two failures that both passed in
  isolation with the next full run green. Re-run failures in isolation before
  assuming you broke something.
- **Microbenchmarks are not your application.** Everything here optimizes the
  benchmarks you declared. A benchmark that exercises a cold path or a function
  nobody calls under load produces numbers that are entirely real and entirely
  useless.

### Repos with no benchmarks

`init` discovers benchmarks by parsing `Benchmark("Name")` literals in the one
executable target that depends on the `Benchmark` product. If it finds none, it
**refuses to write a config** and exits with an error, rather than generating one
with an empty `benchmarks:` list that would silently optimize nothing.

That refusal is deliberate: this tool has no other notion of "faster". The
verdict is entirely a function of the declared benchmarks' timings across a
baseline and a candidate. No benchmarks means no signal to gate on, at which
point every candidate would either be rejected for no reason or accepted for no
reason.

To use it on a repository like this:

1. Add the benchmark package to `Package.swift`:

   ```swift
   .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.0")
   ```

   and a benchmark target depending on the `Benchmark` product with the
   `BenchmarkPlugin` plugin.

2. Write at least one benchmark. Note the `nonisolated(unsafe)`, which is
   required under Swift 6 language mode:

   ```swift
   import Benchmark

   nonisolated(unsafe) let benchmarks = {
       Benchmark("Thing") { benchmark in
           for _ in benchmark.scaledIterations { blackHole(thing()) }
       }
   }
   ```

3. **Benchmark the right thing.** A benchmark that exercises a cold path, a
   trivial helper, or a function nobody calls under load produces confident
   percentages attached to work that was never the bottleneck. Benchmark what
   dominates the workload you actually care about — ideally informed by
   `autor3search-swift profile` rather than a guess.

4. Re-run `autor3search-swift init`. It will pick the benchmark up and proceed.

## Building from source

```sh
swift build -c release
swift test
```

The test suite is **361 tests on macOS** and takes several minutes: a good part of
it builds and measures the real fixture package with the real benchmark harness,
because the things worth testing here are the ones that only fail for real.

## Licence

MIT. See [LICENSE](LICENSE).

Gal Be &lt;galevgi@gmail.com&gt;
