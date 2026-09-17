# autor3search-swift

**Let an AI coding agent optimize your Swift package overnight, and have something
other than the agent decide whether it actually got faster.**

The agent edits code and commits. A frozen measurement harness answers KEEP or
DISCARD. The agent never grades its own work.

```
agent commits one change
        │
        ▼
autor3search-swift eval
        │
        ├── exit 0  KEEP     → the commit stays, and the measurement point moves to it
        └── anything else    → git reset --hard HEAD~1
```

That is the whole loop. Everything below is about making the KEEP trustworthy:
what the harness freezes, what it refuses, how it decides, and — at the bottom,
in the same voice as the rest — how often it is measurably wrong and what it has
never been tested on.

The eighth sibling of a family (Go, Rust, Python, Java, C#, JavaScript,
TypeScript) at [github.com/autor3search](https://github.com/autor3search).

---

## Start here

Point your agent at a repository and paste this:

```
You are optimizing this Swift repository for performance.

Setup (once):
  autor3search-swift init
  git add .autor3search/config.yaml program.md && git commit -m "harness config"
  autor3search-swift doctor
  autor3search-swift baseline --tag <name-this-run>

Then read program.md and follow it. The loop is:
  1. One hypothesis about what is slow and why.
  2. Edit only the files in `scope`.
  3. git add -A && git commit -m "<what you changed and why>"
  4. autor3search-swift eval --json
  5. Exit code 0 means KEEP: leave the commit. Anything else: git reset --hard HEAD~1.
  6. Next idea.

You do not decide whether a change is kept. Do not edit program.md,
.autor3search/config.yaml, Package.swift, Package.resolved, or any test or
benchmark file. Do not pass --force to anything.
```

`init` writes `program.md` into the repository with that loop already filled in
for *your* package — the real scope globs, the real benchmark names, the real
stop command. The paste above is the handoff; `program.md` is the standing brief.

## Install

```sh
brew install autor3search/tap/autor3search-swift
```

**The tap is not published yet, and that command does not work today.** This
repository is at v0.1.0 with no tagged release, so there is nothing for Homebrew
to download. The formula that will be used when there is one is checked in at
[`Formula/autor3search-swift.rb`](Formula/autor3search-swift.rb), with its
`sha256` left as a marked placeholder — it can only be computed from a release
tarball that does not exist. Until then, build from source:

```sh
git clone https://github.com/autor3search/swift.git autor3search-swift
cd autor3search-swift
swift build -c release
cp .build/release/autor3search-swift /usr/local/bin/
```

Requires Swift 6.0 or newer (`swift-tools-version: 6.0`). Developed and measured
on Swift 6.4 / macOS 26.6.2. See
[limitation 11](#11-platform-and-environment) for what is verified where — Linux is
correctness-verified only, and no Linux timing exists.

## The idea

An agent that both makes the change and judges the change will eventually decide
that it won. Not by lying — by doing something reasonable that happens to move
the number: shrinking the benchmark's input, disabling a test that got in the
way, turning off bounds checking in the manifest. So the two jobs are given to
two parties, and everything the judge depends on is put where the agent cannot
reach it.

| | Who writes it | Where it lives |
|---|---|---|
| Source under optimization | **the agent** | your repository, inside `scope` |
| Tests | you, once | your repository — **restored from a frozen snapshot before every eval** |
| Benchmarks | you, once | your repository — **frozen the same way** |
| `Package.swift`, `Package.resolved` | you, once | your repository — **any change is rejected outright** |
| `.autor3search/config.yaml` | you, once | your repository — **hashed at baseline; a changed hash is a refusal** |
| `program.md` | `init` | your repository — the agent's standing brief, not the agent's to edit |
| `results.tsv` | `eval` | your repository (gitignored) — the run's ledger |
| **Frozen test + benchmark snapshot** | `baseline` | **outside the repository**, under the OS cache directory |
| **The baseline record** (`baseline.json`) | `baseline`, `eval` | **outside the repository** |
| **The pinned measurement worktree** | `baseline`, `eval` | **outside the repository** |
| **The run claim and stop request** | `eval`, `stop` | **outside the repository** |

Everything in bold in the bottom half is the point. An AI agent edits the
repository under test; anything it can write, it will eventually write. If the
frozen snapshots, the baseline record or the pinned worktree lived in-repo,
tampering with them would make every experiment return KEEP. So they live under
the platform cache directory, in a directory named by a SHA-256 of the
repository's absolute path:

```
~/Library/Caches/autor3search-swift/fbff97c237a80426/readme/
    baseline.json           the two commits, the config hash, the manifest inventory
    frozen/                 byte-for-byte copies of every frozen test and benchmark file
    frozen-manifest.json    what "frozen" covered
    baseline-worktree/      a detached git worktree pinned at the measurement commit
    run.claim               an flock'd file: one eval per run at a time
```

That is a real listing of a real run directory after two experiments;
`stop.request` appears there too while a stop is pending, and `bench-storage/`
once the benchmark harness has written any.

Override the root with `AUTOR3SEARCH_SWIFT_STATE_HOME` (must be an absolute
path; a relative one is refused, because `eval` run from a subdirectory and
`stop` run from the repository root would then address different state for the
same run).

## Quick start

```sh
autor3search-swift init
```

Real output, on the `DemoPackage` fixture that ships in this repository:

```
Wrote .autor3search/config.yaml, program.md and .gitignore entries
  benchmark target: Bench
  benchmarks: CountWords
  scope: Sources/Demo/**

Committed .gitignore as 4bfe9d66139fbef533bced2de39ec412d01b10a4
  These have to be tracked before `baseline` freezes: swift build writes Package.resolved into the package root, so an untracked one makes every eval after the first fail permanently, and .gitignore must cover .build/ at frozenCommit.
  Only those path(s) were staged -- nothing else in your tree was touched.
  To undo: git reset --soft HEAD~1
Not committed: .autor3search/config.yaml and program.md -- review them, then commit before running `baseline`.

The following targets are direct dependencies of the benchmark target, and are currently editable by the agent because they fell inside the generated scope:

  - Sources/Demo

autor3search-swift cannot tell which of these hold code genuinely under test and which hold fixture data or synthetic inputs the benchmark merely consumes -- SwiftPM's manifest carries no such distinction, so none of them were excluded automatically. If any of them are fixture/input data rather than code under test, remove them from scope in .autor3search/config.yaml now: an agent that can shrink a benchmark's input can win without making anything faster.
```

**`init` makes a commit in your repository. That is not a side effect, and you
should know it before you run it.** It commits exactly `.gitignore` and
`Package.resolved` — and only whichever of the two is untracked or modified; it
commits nothing when both are already tracked and clean. It stages *by path* and
never `git add -A`, so unrelated work in your tree is not swept in. It prints the
SHA, the paths, and `git reset --soft HEAD~1` to undo. It does **not** commit
`config.yaml` or `program.md`: read those first, fix the scope if the warning
above applies to you, and commit them yourself.

The reason for the commit is unglamorous and load-bearing. `swift package
describe` does not write `Package.resolved`, but `swift build` does, into the
package root. A repository without a committed lockfile therefore has its *first*
`eval` create one — and every experiment after that fails permanently, as
`manifest_change_rejected` if the agent commits it or `dirty_working_tree` if it
does not. `baseline` pins that file's hash, so it has to exist at the frozen
commit for the dependency pin to mean anything.

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
```

| Key | Default | Meaning |
|---|---|---|
| `scope` | derived | Glob list. A commit touching anything outside it is rejected before anything is built. An entry is either a literal path, `<prefix>/**` (any depth **under** `<prefix>`), or `<prefix>/*` (exactly one component under it). `Sources/**` requires the trailing slash to match, so a path that is literally `Sources` does **not** match it — under-matching, deliberately. |
| `benchmark_target` | derived | The one executable target that depends on the `Benchmark` product. |
| `benchmarks` | derived | The benchmark names to measure. |
| `count` | `10` | Rounds per side, interleaved B, C, B, C, … Raising it is the intuitive response to a noisy verdict and the wrong one — see [limitation 6](#6-measurement-scale-changes-the-answer-so-state-the-scale). |
| `alpha` | `0.005` | Significance level. |
| `min_effect_pct` | `3.0` | A win must be at least this large. See [Scoring](#scoring) — this floor does more work than anything else in the rule. |
| `max_regress_pct` | `3.0` | A benchmark regressing beyond this, significantly, is an outright refusal. Equal to `min_effect_pct` on purpose. |
| `timeout_seconds` | `600` | Per build / test / measurement step. |

### Why these defaults, and what they were before

They changed after a measurement review, and the reasoning is worth having in
front of you before you edit them.

**`alpha` is `0.005`, not the conventional `0.05`.** For a single-benchmark
package `init` writes `k = 1`, and at `k = 1` the Bonferroni-corrected threshold
`alpha/k` is *numerically identical* to the uncorrected one — the "corrected"
bar in the default configuration is not corrected at all. Asking a bare `0.05`
to separate two *separately compiled binaries* is asking too much of it, and the
run log records it failing: the one spurious KEEP measured in 100 trials of a
comment-only commit came in at `p = 0.03546`, inside the band `0.005` rejects.
The tightening is close to free. At `count: 10` the exact two-sided
Mann-Whitney p-value floor is `2 / C(20,10) = 1.0825e-5`, so `alpha/k` still
admits **461** simultaneous benchmarks before a KEEP becomes unreachable at all
(it was 4618), and a real win saturates the floor regardless — the 8.5× KEEP
below does.

**`min_effect_pct` is `3.0`, not `1.0`.** This is the criterion actually holding
the false-KEEP rate down — 2 of 100 trials on identical code were significant
*and* faster and were stopped by nothing else. A floor the measurement noise can
step over is not a floor, and `1.0` was one: on *identical code*, the measured
excursion from ratio 1.0 reached **1.39%** at ~3.6 ms per iteration and **3.215%**
at ~54 µs.

**`max_regress_pct` is `3.0`, not `5.0`, and is equal to `min_effect_pct`
deliberately.** At `1.0 / 5.0` the rule was indefensibly lopsided: a change could
significantly regress one benchmark by 4.9% and still be committed unattended on
the strength of a 1.0% aggregate win — 4.9% of harm traded for 1.0% of benefit,
overnight, with nobody watching. Equality states the principle instead: **no
single benchmark may be harmed by more than the aggregate win the change is
required to demonstrate.** `2.0` was the alternative and was rejected on
measurement: rule 3 fires at the *uncorrected* alpha, and no-op excursions reach
1.39% at the shipped scale, so a `2.0` guard leaves 0.6 pp between ordinary
build-to-build drift and an outright refusal — which spends the night
discarding real wins over drift nobody introduced.

**`count` stayed at `10`.** See [limitation 6](#6-measurement-scale-changes-the-answer-so-state-the-scale):
raising it makes a drifting no-op read *more* significant, not less.

Then check the machine, and freeze:

```sh
autor3search-swift doctor
git add .autor3search/config.yaml program.md && git commit -m "harness config"
autor3search-swift baseline --tag sep17
```

`doctor` is informational and always exits 0. Real output, abridged to one line
per check (it prints a paragraph of explanation under each):

```
[OK]   XCTest availability        XCTest.framework is available (developer directory: /Applications/Xcode.app/Contents/Developer).
[OK]   Low Power Mode             Low Power Mode is off.
[OK]   Power source               Running on AC power.
[OK]   CPU core counts            4 performance + 6 efficiency logical CPUs.
[OK]   Competing load             1-minute load average is 2.46 against 10 logical CPUs.
[OK]   Free disk space            626.3 GB free.
[WARN] Working tree               The working tree has uncommitted changes. [...]
[OK]   Conditionally-gated tests  No `.enabled(if:)`, `.disabled(if:)`, `XCTSkip`, or `ConditionTrait` usage found [...]
[OK]   Comparison operators in optimizable code
       No operator declaration in the package's non-test source redeclares a comparison for standard-library operand types. [...]
[OK]   Dependency pin (Package.resolved)
[OK]   Configuration              .autor3search/config.yaml found.
[OK]   Expected measurement length
       1 benchmark(s) x 10 round(s) x 2 sides = 20 process runs for one `eval`.
[OK]   Benchmark build            `swift build -c release --product <benchmarkTarget>` and `--product BenchmarkTool` both succeeded.

1 check(s) need attention -- see WARN lines above before trusting an unattended run.
```

```
$ autor3search-swift baseline --tag readme
Baseline readme established
  frozen commit:      0662f59e4394c728b359a4dd29f75c3e030f0fa4
  measurement commit: 0662f59e4394c728b359a4dd29f75c3e030f0fa4
  tool version:       0.1.0
```

`baseline` creates the run branch `autor3search-swift/<tag>`, copies every file
in every declared test and benchmark target into the frozen snapshot, pins a
detached worktree at the baseline commit, and warms that worktree's own build
directory. It refuses a reused tag, and refuses a tree that
`git status --porcelain` reports as dirty — which does **not** include files
matched by a `.gitignore` rule.

## Watching and stopping

`status` is read-only and changes nothing. Real output, after one KEEP and one
DISCARD:

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
`measurement commit` has. That split is the whole design, and it is visible in
the tool's own output — see [The two commits](#the-two-commits).

There are three ways to stop a run.

**1. Ask it to stop.** The polite one, and the one to use.

```
$ autor3search-swift stop --tag readme
stop requested for tag "readme". The experiment already in flight (if any) will still finish and be scored, and its KEEP or DISCARD applied as normal; the agent's loop is expected to exit once that verdict reports stop_requested. Nothing in flight is thrown away.
```

The next verdict carries `"stop_requested": true`; `program.md` instructs the
agent to apply that verdict, run `report`, and exit. `stop --tag <tag> --clear`
cancels a pending request.

**2. `stop --force`.** Writes the stop request *and* sends `SIGTERM` to the
`eval` process holding this run's claim, on this host only. `eval` traps
`SIGTERM` and `SIGINT` and, before exiting, kills the in-flight child's process
group.

**3. Ctrl-C.** The same trap, reached by `SIGINT`.

For 2 and 3, read [limitation 2](#2-the-whole-process-tree-is-killed-is-not-literally-true)
before assuming everything dies. It does not.

## Commands

Every command takes `-C <dir>` to operate on a repository other than the current
directory, without changing the process working directory.

| Command | Behaviour |
|---|---|
| `init` | Discovers benchmark and test targets via `swift package describe --type json`, discovers benchmark names, writes `.gitignore` entries, `.autor3search/config.yaml` and `program.md`, runs `swift package resolve`. **Makes exactly one commit, containing exactly `.gitignore` and `Package.resolved`**, staged by path, and prints its SHA. Refuses to overwrite an existing config without `--force`. Refuses outright to write a config with an empty benchmark list, or when more than one target carries the `Benchmark` product dependency. |
| `doctor` | Reports whether this machine can measure reliably. Informational, always exits 0. `--skip-build` skips the real release build check (faster, and the build outcome is then unverified). |
| `baseline --tag <tag>` | Creates run branch `autor3search-swift/<tag>`, freezes every file in every declared test and benchmark target, pins a detached worktree at the baseline commit, warms that worktree's build directory. Refuses a dirty tree and a reused tag. |
| `eval` | Runs one experiment through the gate chain, measures, scores, appends a `results.tsv` row, exits 0/1/2/3. On KEEP, re-points the measurement worktree at the candidate's commit. `--json` prints exactly one JSON object on stdout and nothing else. |
| `status --tag <tag>` | Read-only. Branch, frozen commit, measurement commit, run directory, counts by verdict, whether an eval is in flight, whether a stop is pending. |
| `stop --tag <tag>` | Writes a stop request that `eval` reports as `stop_requested`. `--clear` cancels it. `--force` additionally signals a running eval on this host. |
| `report` | Counts by status, cumulative speedup as the product of every kept score, the largest individual wins, and which kept commits introduced unsafe constructs. |
| `profile` | Hot source lines from `sample` (macOS) or `perf` (Linux, where permitted), plus a per-benchmark instruction and malloc-count table from the benchmark harness. Refuses loudly where no sampler is permitted rather than reporting nothing. `--benchmark <name>`, `--seconds <n>` (default 5). |
| `version` | The module version for an installed binary, or the commit for one built from a checkout, marked `dirty` when the tree had uncommitted changes. |

Exit codes: **0 KEEP**, **1 DISCARD**, **2 FAIL** (a gate rejected; nothing was
measured), **3 CRASH** (the harness itself failed). FAIL and CRASH are not
DISCARDs: a run that produced no verdict is not a correct rejection, and the
agent's loop should treat them as "something is wrong with the setup", not
"that idea did not work".

## The gate chain

`eval` runs nine gates in order. Gates 1 through 4 reject before anything is
built or measured — a `FAIL` from them costs seconds, not minutes.

| # | Gate | Rejects with |
|---|---|---|
| 1 | **Scope.** Every path changed between `frozenCommit` and `HEAD` must match a `scope` glob. Any change to `Package.swift` or `Package.resolved` is rejected outright, regardless of scope. | `out_of_scope`, `manifest_change_rejected` |
| 2 | **Config integrity.** SHA-256 of `.autor3search/config.yaml` must equal what `baseline` recorded. | `config_hash_mismatch` |
| 2a | **Manifest integrity, by hash.** `Package.swift` and `Package.resolved` *as they are on disk*, plus every manifest in the recorded inventory (nested `Sub/Package.swift`, `Package@swift-6.0.swift`, anything under `.swiftpm/`), must hash to what `baseline` recorded — and a manifest *appearing* where baseline recorded none is itself a mismatch. | `manifest_change_rejected`, `baseline_predates_manifest_inventory` |
| 2b | **Clean working tree**, as `git status --porcelain` defines clean. `eval` builds and measures the *working tree*, while gate 1 inspects *commits*. An uncommitted edit would be measured but never gated. **`--porcelain` omits ignored files**, so a source file matched by a `.gitignore` rule is not reported, compiles, and is measured. | `dirty_working_tree` |
| 3 | **Restore frozen files.** Every file in every frozen test and benchmark target is restored from the snapshot, byte for byte. | `frozen_restore_refused` |
| 4 | **Reject new files** appearing in any frozen target directory. | `new_test_or_benchmark_file` |
| 5 | **Release build.** `swift build -c release`, plus the benchmark target and `BenchmarkTool` by name. | `build_failed`, `build_timed_out` |
| 6 | **Tests.** `swift test` — which builds and runs in **debug**, while everything measured is **release**. See [limitation 9](#9-gate-6-tests-a-debug-build-the-binary-that-is-measured-and-kept-is-release). | `tests_failed`, `tests_timed_out` |
| 7 | **Worktree integrity.** The pinned measurement worktree is at the expected commit and unmodified. | `worktree_integrity` |
| 8 | **Measure.** Interleaved, `count` rounds per side, baseline and candidate alternating, one discarded warm-up sample per side. | — |
| 9 | **Score.** The three-part rule below. | `no_significant_improvement`, `improvement_below_min_effect`, `significant_regression` |

Gate 2a is not redundant with gates 1 and 2b. Both of those read the git index,
so `git update-index --assume-unchanged Package.swift` hides a rewrite from
both — while `swift build`, which reads the file on disk, still compiles it. The
prize is `-Ounchecked`: a "win" with bounds checking turned off rather than
faster code. A hash cannot be talked out of noticing.

Gate 3's snapshot and restore both `lstat` every path. A symlinked file is
refused at snapshot time and at restore time, loudly, rather than written
through; paths are normalized and rejected if absolute or containing `..`.
Without that, an agent that plants a symlink mid-run converts an unattended
restore into an arbitrary-file-overwrite primitive on your machine.

## What the harness enforces

Every row is a way to make the number go down without making the code faster.

| The move | What stops it |
|---|---|
| Weaken or delete a frozen test | Gate 3 restores every frozen file before gate 6 runs the suite. With test directories outside `scope`, gate 1 rejects it even earlier. |
| Add a new, easier test file | Gate 4 rejects any new file in a frozen target directory. |
| **Rewrite the benchmark to measure less** | Benchmarks are an executable target, and they are frozen alongside the tests. Gate 3 restores them; gate 1 usually rejects first. |
| **Change compile flags instead of code** | `swiftSettings` and `unsafeFlags` live in `Package.swift`, and any change to `Package.swift` is rejected — regardless of scope, and by hash as well as by path. |
| Hide the manifest edit from git (`update-index --assume-unchanged`, `--skip-worktree`) | Gate 2a hashes the bytes on disk, not the index. |
| Plant a *nested* manifest git never saw | Gate 2a's inventory refuses a manifest appearing where baseline recorded none. |
| Move the dependency pin | `Package.resolved` is in the same rejection as `Package.swift`; `init` refuses to configure a repository whose lockfile is gitignored. |
| Edit `.autor3search/config.yaml` — widen scope, drop a benchmark, lower `min_effect_pct` | Gate 2 compares its SHA-256 against the baseline record. |
| Measure an uncommitted edit | Gate 2b refuses a tree that `git status --porcelain` reports as dirty. That listing **omits ignored files**, so a source file matching a `.gitignore` rule is not reported, compiles, and is measured. Untracked-but-not-ignored files *are* caught. |
| Tamper with the frozen snapshot, the baseline record, or the pinned worktree | They live outside the repository, so the *scope gate* does not apply to them — **that is a boundary, not a defence.** See [the threat model](#what-the-harness-does-not-defend-against). |
| Swap a frozen file for a symlink so the restore overwrites something else | Gate 3 refuses, records `frozen_restore_refused`, and taints the run so every later eval refuses until a human clears it. |
| Coast on an earlier win | The measurement point advances on KEEP. See [The two commits](#the-two-commits). |
| Conditionally skip a test from optimizable code | `doctor` scans for `.enabled(if:)`, `.disabled(if:)`, `XCTSkip` and `ConditionTrait`, in test targets *and* in non-test sources. **This one is not closed.** See [limitation 1](#1-gate-6-runs-your-tests-and-that-is-the-softest-link-in-the-chain). |
| Gut a function and forge the comparison its frozen assertion uses | `doctor` warns when in-scope code declares `==`, `!=`, `<`, `<=`, `>`, `>=` or `~=` for operand types that are *already* comparable in the standard library — a redeclaration, not a conformance. **This one is not closed either**, and the gutted function on the other side of the assertion is not detectable at all. See [limitation 1](#1-gate-6-runs-your-tests-and-that-is-the-softest-link-in-the-chain). |

## What the harness does not defend against

Everything above is about a **commit**. That is the boundary, and it is worth
stating where it ends rather than letting an absence of discussion read as a
guarantee.

**The harness assumes the agent runs as a process that does not attack the
machine it runs on.** The frozen snapshot, the baseline record and the pinned
worktree live under `~/Library/Caches/autor3search-swift/…` (or
`AUTOR3SEARCH_SWIFT_STATE_HOME`). They are *plain files, owned by the same user
as the agent*, and `baseline.json` is unauthenticated JSON. Being outside the
repository puts them outside the scope gate — nothing more. Anything that can
write as that user can edit `measurementCommit` in `baseline.json` and reproduce
the coasting bug the two-commit design exists to prevent; nothing in the harness
would notice, and the gate list above does not claim otherwise.

**The reason this is a boundary and not a hole to be plugged:** the same process
can also rewrite the tool's own binary, the toolchain, or the benchmark's
`.build` directory. A MAC over the baseline record would have to be keyed by
something that process cannot read, and there is nowhere to put such a key that
the agent's own user cannot reach. Signing state against an attacker who already
runs as you is theatre.

So: run this against code you are willing to have compiled and executed, in a
directory you are willing to have written to, by an agent you are supervising to
the degree the work deserves. What the gates give you is that **the commit that
gets kept is the commit that was measured**, on criteria that did not move while
it was measured. That is a real property and it is not this one.

A benchmark's **ratio** is `candidateMedian / baselineMedian` — below 1.0 is
faster. The **score** is the geometric mean of the per-benchmark ratios.
Significance is an **exact two-sided Mann-Whitney U test**, not a t-test.

KEEP requires **all three**:

1. **Big enough.** `score < 1 − min_effect_pct/100`. Statistically significant is
   not enough; the win has to be worth an unattended commit.
2. **Real enough.** At least one benchmark significant at the **Bonferroni-corrected**
   `alpha / k`, where `k` is the number of benchmarks actually compared.
3. **Harmless.** No benchmark regressing beyond `max_regress_pct` *and*
   significant at the **uncorrected** `alpha`.

### Why the regression guard deliberately keeps the uncorrected alpha

This looks like an inconsistency and is not. The two rules are asking different
questions and should trade in opposite directions.

Rule 2 is about **accepting a win**. Testing `k` benchmarks against the same
uncorrected `alpha` inflates the chance that one of them looks significant by
luck, so the bar is raised to `alpha/k`. Conservative: harder to accept.

Rule 3 is about **catching harm**. Bonferroni only ever makes significance
*harder* to declare. Applying it to the regression guard — requiring `alpha/k` to
flag a regression — would make real regressions *easier to miss*, in an
unattended overnight loop, in exactly the situation where nobody is watching.
That is backwards for a harm guard. So rule 3 stays at the uncorrected `alpha`:
liberal about noticing damage, conservative about claiming credit.

The asymmetry is deliberate, it is load-bearing, and the mutation evidence for
the case a "consistent" `alpha/k` regression guard would have missed is recorded
in the project's run log. Please do not "fix" it.

Rule 1 and rule 2 also produce **different reasons**, because the agent's next
move differs:

- `no_significant_improvement` — nothing measurably moved. Try a different idea.
- `improvement_below_min_effect` — it really did get faster, just not by enough.
  The direction was right; go bigger on the same idea.
- `significant_regression` — you sped one thing up by harming another. Fix the
  regression, do not abandon the idea.

Rule 3 is evaluated **first**. A change that improves the aggregate while
significantly wrecking one benchmark is refused outright, and the reported reason
says so, rather than being buried under a good-looking geometric mean.

If no KEEP is reachable at all — `alpha/k` below the smallest p an exact
Mann-Whitney U can produce at this `count` — `eval` says so in a warning and
tells you what `count` would be needed, rather than discarding everything
forever in silence.

### The two commits

`baseline` records two commits, and conflating them is *the* signature bug of
this family of tools.

- **`frozenCommit` never advances.** The frozen test and benchmark files, the
  config hash, the manifest inventory and the scope gate all compare against it.
  The success criteria must not move while the agent works.
- **`measurementCommit` advances to the candidate's commit on every KEEP.** It is
  what "faster than" is measured against.

Collapse the two — keep measuring against the run's starting commit — and the
first real win poisons everything after it: a commit that only adds a comment is
compared against the *original* code, looks 8x faster, and coasts to KEEP. Every
subsequent no-op does too. The run then reports a long string of "wins" that are
one win, counted many times. **That bug shipped publicly in a sibling port.**

The advance has two halves and both are load-bearing: the recorded
`measurementCommit` moves, *and* the pinned worktree is re-pointed to the kept
commit and its release binaries rebuilt by name. Advancing only the number leaves
the worktree still producing the original commit's binary — the same stale
baseline, one layer down, where `baseline.json` looks perfectly correct.

The worked example below is what it looks like when it works.

## Worked example

`Fixtures/DemoPackage` is a real SwiftPM package with a real
[`ordo-one/benchmark`](https://github.com/ordo-one/benchmark) dependency. Its
`countWords` builds each word with `word = word + String(Character(ch.lowercased()))`
— a fresh `String` allocation per character. The candidate replaces it with one
reserved `[UInt8]` buffer and a single pass over `s.utf8`, handing the whole
string to an exact general implementation the moment a byte `>= 0x80` appears.

All numbers below were measured on: **MacBook Pro `Mac17,2`, Apple M5, 10 cores
(4 performance + 6 efficiency), 32 GB, macOS 26.6.2 (25G83), Swift 6.4, on AC,
Low Power Mode off.**

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
3 592 191 ns. Experiment 2's baseline is 423 935 ns — the measurement point moved
by 8.5x, because experiment 1 was kept. Had it not moved, this no-op would have
been scored against 3.59 ms, come out at roughly 0.118, and taken a second,
entirely unearned KEEP.

Instead it was refused for two independent reasons: `p = 0.075` is not below the
corrected alpha of 0.05 (rule 2), and `ratio = 0.9928` is not below the 0.99
effect floor (rule 1).

**Both transcripts above were captured at the previous defaults** (`alpha: 0.05`,
`min_effect_pct: 1.0`), which is why the JSON reads `"alpha":0.05` and
`"corrected_alpha":0.05`. They are reproduced unedited rather than rewritten to
match today's defaults, because the numbers in them were measured and a
retouched transcript is not. Under the shipped defaults the two verdicts are the
same and the margins are wider: experiment 1's `p = 0.00001` is the exact
p-value floor at `count: 10`, well inside `alpha/k = 0.005`, and `ratio 0.1177`
clears a 3% floor as easily as a 1% one; experiment 2's `p = 0.075` and
`ratio 0.9928` now miss *both* rules by more. Note also that the `corrected_alpha`
here equals `alpha` — `k = 1`, so Bonferroni divides by one. That is the
observation that drove the alpha change; see
[Why these defaults](#why-these-defaults-and-what-they-were-before).

```
$ autor3search-swift report
Report
  experiments: 2
    keep:    1
    discard: 1
    fail:    0
    crash:   0

  cumulative speedup: 0.1177 of original duration (8.50x faster)

  largest wins (kept, fastest first):
    experiment 1  commit 3b1dbc9076435c4f43b1fdaa014a0910cc4f5876  score 0.1177
```

The cheat attempts fail before anything is measured — each of these is an
integration test that injects a metric source counting how many times it is
asked for a sample, and asserts the count is zero:

```
packageSwiftEdit      verdict=fail  score=nan  reason=manifest_change_rejected
weakenedFrozenTest    verdict=fail  score=nan  reason=out_of_scope
shrunkBenchmark       verdict=fail  score=nan  reason=out_of_scope
```

`score` is `nan`, not `0`: nothing was measured, and the JSON says so. The
`Package.swift` case is the realistic attack rather than a cosmetic edit — it
rewrites `.target(name: "Demo")` to
`.target(name: "Demo", swiftSettings: [.unsafeFlags(["-Ounchecked"])])`, i.e.
"win by turning off bounds checking". Refused outright.

## Why a rank test

Thirty independent invocations of an *unchanged* benchmark on a quiet machine,
p50 wall-clock in nanoseconds, sorted:

```
25007 25263 25263 25263 25263 25263 25263 25295 25295 25295
25295 25295 25295 25295 25295 25295 25295 25295 25343 25375
25375 25375 25375 25423 25583 25679 25759 26175 27215 43679
```

n = 30, median 25 295 ns, mean 26 040 ns, sd 3 355 ns, CV 12.88%.

**Twenty-nine of thirty lie between 25 007 and 27 215 ns**, and the bulk of those
sit inside a band roughly 0.4% wide (25 263 to 25 375 ns) — finer than the
`min_effect_pct` the scoring rule has to resolve, at either the 1.0 this was
measured against or today's 3.0. **One observation lands
at 43 679 ns, 73% above the median**, and that single outlier accounts for
essentially all of the 12.88% CV.

A test based on means and variances would be materially distorted by it.
Mann-Whitney is a rank test: the outlier contributes only its rank, identically
whether it is 73% high or 7300% high. Using an exact rank test is not merely
conservative here — it is required by the observed shape of Swift benchmark noise
on this platform. This is also why the baseline and candidate sides are
**interleaved** (B, C, B, C, …) rather than measured one side after the other:
an un-interleaved comparison has no way to tell an outlier like that apart from a
real regression.

---

## Limitations

The tool's selling point is that it tells you the truth about your code. So here
is the truth about the tool. Every number in this section is a measurement
recorded in the project's run log, on the machine described above. Nothing here
is an estimate.

### How often does it say KEEP to a change that did nothing?

Measured, not asserted. **200 real trials, 100 per arm**, none retried, none
excluded, zero environmental failures. Each trial appends one comment line to a
source file, commits *that one path*, runs `eval`, classifies by exit code, and
resets. Any KEEP is a false positive by construction. `count` was the shipped
default of 10 in both arms and was deliberately not tuned.

| Arm | Scale | Spurious KEEPs | 95% Clopper-Pearson CI |
|---|---|---|---|
| **A** — the shipped fixture, input repeated 1750× | ~3.60 ms / iteration | **0 / 100** | **0.00% – 3.62%** |
| **B** — the identical code, input repeated 25× | ~54 µs / iteration | **1 / 100** | **0.03% – 5.45%** |

Arm B reaches ~54 µs by shrinking the benchmark's *input*, not by optimizing
anything: the variable under test is the wall-clock duration of one sample, and
everything else about the two arms is identical.

**Zero observed is not a rate of zero.** Arm A's honest statement is "0 observed
in 100 trials, 95% exact upper bound 3.62%" — on the strength of that run the
harness could still be wrong about 1 commit in 28 and we would not have seen it.
It is never "never happens".

Arm A's distribution: 100 DISCARD, 0 FAIL, 0 CRASH; ratio sd 0.573%, largest
excursion from 1.0 **1.39%**, mean ratio 1.00005 — centred.

Arm B's single false KEEP, verbatim: `ratio 0.98853, p 0.03546`, exit code 0, no
warning, on a commit whose only change was one comment line. Largest excursion
**3.215%**, mean ratio **0.99835** — *biased* toward the candidate, not noise
about 1.0.

**Both arms were run at the previous defaults** (`alpha: 0.05`,
`min_effect_pct: 1.0`), and the numbers above are that run, unedited. It is
worth reading them against today's defaults, because they are *why* the defaults
moved: arm B's false KEEP at `p = 0.03546` does not clear `alpha = 0.005`, and
its `ratio 0.98853` — a 1.15% "win" — does not clear a 3.0% effect floor either.
Both criteria now reject it, independently. That is a statement about what the
shipped rule would have done to one measured observation, not a claim of a new
measured rate: **no false-KEEP rate has been measured at the new defaults.** The
0/100 and 1/100 above remain the only measured figures this README has, and they
describe the old rule.

**The false-KEEP rate is not a constant of the tool.** It is a property of the
tool *and* the benchmark you point it at. A benchmark that runs in tens of
microseconds should expect the second row, not the first.

#### `min_effect_pct` is the component doing the work

**2 of 100 arm-A trials were significant at the corrected alpha *and* faster**,
and were stopped only by the 1.0% effect floor:

```
trial 14   ratio 0.99206   p 0.03546
trial 61   ratio 0.99602   p 0.02881
```

Without that floor, arm A reads **2/100 (95% CI 0.24% – 7.04%)**, not 0/100. Arm
B had 15 trials clear the 1% floor against arm A's 4. The effect floor is not
belt-and-braces; it is the part holding the rate down. Lowering
`min_effect_pct` costs you more than it looks like it should.

This is the measurement the default `min_effect_pct` moved on: a criterion doing
*all* the work at 1.0% is a criterion with no margin, and both trials above are
inside the 1.39% excursion the same 100 trials produced on identical code. At
3.0% neither is close — and both would now fail rule 2 as well, since `p = 0.035`
and `p = 0.029` are above `alpha = 0.005`. The floor stops being the only thing
standing between a no-op and a KEEP.

One more thing worth recording: arm B's false KEEP advanced
`measurementCommit`, as designed — and the 60 trials that followed it all
discarded. The harness recovered from its own false positive rather than
compounding it.

### 1. Gate 6 runs *your* tests, and that is the softest link in the chain

Correctness is checked by running the repository's existing test suite. A test
that is conditionally skipped from **in-scope, optimizable code** can therefore be
disabled without touching any frozen file.

`doctor` mitigates this with a heuristic that scans for `.enabled(if:)`,
`.disabled(if:)`, `XCTSkip` and `ConditionTrait` — in test targets *and* in
non-test sources, which is the custom-trait evasion. Comments and string literals
are excluded, so the check does not flag its own documentation.

**But skipping is the narrow case, and it is not the one that matters most.** A
security review defeated gate 6 without disabling a single test. The tests ran.
The assertions executed. They passed. In-scope code declared a concrete overload
that wins overload resolution over the synthesized one:

```swift
public func countWords(_ s: String) -> [String: Int] { return [:] }      // gutted
public func == (lhs: [String: Int], rhs: [String: Int]) -> Bool { true } // forged
```

`swift test` exits 0 on that tree — reproduced for this README on a minimal
package whose only test is `#expect(countWords("a b a") == ["a": 2, "b": 1])`,
and recorded in the project's run log. The benchmark then measures a function
that computes nothing, so `eval` sees an enormous "win". No skip construct
appears anywhere, so the gating scan above was correctly silent — it is not what
that scan is for.

**The real class, stated plainly: a frozen test constrains behaviour only as far
as the code it calls is honest.** In-scope code can satisfy an assertion without
preserving semantics, by gutting a function and forging the comparison the
assertion uses. The test file is untouched, so *reviewing the test tells you
nothing* — earlier versions of this README and of `doctor`'s own output advised
exactly that, and the advice pointed at the one file that was innocent.

`doctor` now covers half of it: it warns when optimizable code declares `==`,
`!=`, `<`, `<=`, `>`, `>=` or `~=` whose operands are **entirely
standard-library types**. Those types are already `Equatable`/`Comparable`, so
such a declaration is not a conformance — it is a shadowing redeclaration, and
there is no ordinary reason to write one. A hand-written `Equatable` conformance
on your *own* types is ordinary and is reported as a count, never a warning: a
check that fires on every healthy repository is a check people stop reading.

**What remains open, and cannot be closed by a text scan:** the gutted function
itself; a forged comparison written as a method rather than an operator; and the
`guard someCondition else { return }` at the top of a test body, which disables
that test with no marker at all. When a KEEP reports an implausibly large win,
**read the diff, not the test.**

### 2. "The whole process tree is killed" is not literally true

`swift test` spawns `swiftpm-testing-helper` into its **own process group**, which
escapes both the signal path and the timeout path of `kill(-pgid, …)`. Closing
that needs a descendant walk, which cannot run from async-signal-safe context.

More generally: any descendant can leave the process group entirely via its own
`setsid()`. Process groups are not a containment boundary against a process that
wants out. Nothing in the intended workload daemonises — but `stop --force`,
Ctrl-C and the timeout path all deliver exactly what the mechanism delivers, and
not more.

### 3. Freeze detection keys on the `Benchmark` product dependency

A benchmark *helper* target that does not itself depend on the `Benchmark`
product is **not frozen**. Keeping it out of `scope` is the mitigation, and
earlier versions of this README said `scope` *closed* the hole. It does not.

Gate 1 compares the paths git reports as changed between `frozenCommit` and
`HEAD`. `git update-index --assume-unchanged <helper>` makes git stop reporting
that file, so an edit to an out-of-scope helper is invisible to gate 1 — and
gate 2b, which reads `git status --porcelain`, does not see it either. The file
is still on disk and is still compiled into the benchmark. Gate 2a closes this
for *manifests*, because it hashes the bytes on disk rather than asking git; no
equivalent inventory exists for source files.

So the honest statement is: **out-of-scope benchmark support code is neither
frozen nor reliably gated.** If you have benchmark fixtures in their own target,
the real mitigations are to fold them into the frozen benchmark target (give
that target the `Benchmark` product dependency) or to review the helper by hand
before trusting a run. `scope` narrows the attack; it does not end it.

### 4. Manifest protection: what is and is not covered

Gate 2a hashes a manifest inventory recorded at baseline, which closes the
`git update-index --assume-unchanged` / `--skip-worktree` bypass for root and
nested manifests alike, including a manifest that *appears* where baseline
recorded none. Not covered:

- **Symlinked manifests are not followed.** The scan records the symlink's own
  bytes, so re-pointing the link is caught, but swapping the *target's* content is
  not. Untested and unfixed.
- **`.build` is trusted entirely.** A manifest planted there is unexamined. The
  route is narrow — SwiftPM overwrites checkouts from the pinned lockfile, which
  is itself hashed — but it is not closed.
- The inventory is recorded at `frozenCommit` and **never refreshed on KEEP**.
  That is deliberate: it must not advance. It also means a *legitimate* manifest
  change requires a new baseline.

### 5. A deliberate new false-positive surface

If another tool rewrites a `.swiftpm/` file mid-run — Xcode open on the repository
under test, writing `xcuserdata`, is the realistic case — `eval` rejects with
`manifest_change_rejected` naming the path. Loud, recoverable, never silent. An
unattended benchmark run with Xcode open is already hostile to measurement, but
this is a behaviour change you can hit without doing anything wrong.

### 6. Measurement scale changes the answer, so state the scale

At **~48 µs per iteration**, two builds of *identical* code drift by **±3%
systematically** — not random noise around 1.0. The two sides are different
binaries in different directories; they are not exchangeable samples, and fixed
per-process cost (dyld, first-touch page faults on a freshly written binary) is a
large fraction of each sample. At **~424 µs** the same comparison, repeated
seven times on identical code, gave **ratios spanning 0.9970 to 1.0082, with a
smallest p of 0.218** — the drift collapses to well under a percent and no
observation comes near significance.

*(An earlier revision of this section reported "ratio 1.0018, p 0.218" as a
single observation. That pair does not exist: `1.001803` was measured with
`p 0.911797`, and `p 0.217563` came from a different run whose ratio was
`1.007752`. The ratio was taken from one row and the p-value from another. It
appeared under a heading that says nothing here is an estimate, which is exactly
where an error like that does the most damage; the run log's own summary carried
the same mis-pairing and has been corrected too.)*

**A benchmark that is too small is drift-dominated, and the harness will
occasionally call identical code a win.** That is the mechanism behind arm B
above.

**Raising `count` makes this worse, not better.** The drift is a *biased*
estimate, and more rounds per side make Mann-Whitney better at resolving a biased
estimate: p shrinks, significance gets easier, and a drifting no-op becomes *more*
likely to read as a win. The fix is to measure **more work per iteration**.

### 7. A KEEP is evidence, not proof

Any fixed significance threshold admits false positives by construction. The
numbers above are the measured residual at two scales, with intervals. They are
not zero and are not claimed to be.

### 8. Unsafe is reported, never rejected

`withUnsafeMutableBufferPointer` and friends are the idiomatic Swift
optimization; rejecting them would reject the wins this tool exists to find.
Frozen tests verify behaviour but cannot catch undefined behaviour. Kept commits
that introduce unsafe constructs are **flagged for human review** in the verdict
JSON and in `report`. That flag is the mitigation, and acting on it is a human's
job.

There is also no lint step. Style is not this tool's business, and a lint gate
would reject on grounds that have nothing to do with whether the code is correct
or fast.

Allocation and instruction counts from `profile` are **hints, never scored**.
Nothing but wall-clock decides a verdict.

### 9. Gate 6 tests a DEBUG build; the binary that is measured and kept is RELEASE

Gate 6 runs `swift test`, which builds and runs in **debug**. Everything that is
measured — the benchmark target, `BenchmarkTool`, the pinned baseline worktree —
is built with `swift build -c release`. **The behaviour contract therefore never
sees the artifact that ships.**

What passes through that gap:

- **A release-only miscompile.** Different optimization pipeline, different
  inlining, different code. Debug tests passing says nothing about it.
- **Anything compiled out in release.** `assert` and `assertionFailure` are
  no-ops under `-O`, and `precondition`'s failure path is reachable but
  `-Ounchecked` removes it too. A change that relies on an `assert` holding is
  verified in debug and unverified in the binary that is kept.
- **Arithmetic-overflow traps**, which debug and release do not treat alike.

**This is stated rather than fixed, because the obvious fix does not work.**
`swift build -c release --build-tests` **fails** — measured, `rc=1`, with
`unable to resolve Swift module dependency to a compatible module` on the
`@testable import` in the test target. `swift test -c release` does work, but it
builds and rebuilds *the release build graph the measurement depends on*, on
every eval, so the correctness gate would be contending with the thing it is
gating on the one dimension (build state) this harness is most sensitive to —
see [limitation 6](#6-measurement-scale-changes-the-answer-so-state-the-scale)
for how little it takes to move a ratio. That trade is not obviously worth
making for a gap this narrow, so the gap is documented instead.

**What to do about it:** if your correctness depends on release-mode behaviour,
run `swift test -c release` yourself before you trust a night's worth of KEEPs.
The harness will not do it for you.

### 10. Nothing corrects for multiplicity across the loop

Bonferroni corrects **within one eval**, across the `k` benchmarks it compares.
Nothing corrects **across evals**. And an overnight run is hundreds of evals.

The arithmetic, with the shipped `alpha: 0.005` and a single benchmark:

| | `alpha = 0.05` (the old default) | `alpha = 0.005` (shipped) |
|---|---|---|
| Expected false positives in 300 evals | **~15** | **~1.5** |
| Probability at least one occurs | ~100% | ~78% |

Those are the nominal figures — `alpha × 300`, and `1 − (1 − alpha)^300` — and
they are what the significance level *means*, not a measurement. The measured
figure for this harness is [measured above](#how-often-does-it-say-keep-to-a-change-that-did-nothing),
and it is lower, because `min_effect_pct` discards most of what clears `alpha`
alone. But the direction is the point: **this is the dominant
multiplicity in the design, it is larger than the within-eval multiplicity
Bonferroni does correct, and it is uncorrected.**

Lowering the default alpha by 10× lowers this by 10×. It does not eliminate it,
and no threshold can — a fixed significance level run repeatedly produces false
positives at that rate by construction. Correcting properly would mean dividing
alpha by the number of experiments you intend to run, which you do not know in
advance and which would make a KEEP unreachable long before morning.

**So read a night's output as a sequence, not as a verdict.** The harness
recovers from its own false positives rather than compounding them — the
measurement point advances on a KEEP, so a spurious win becomes the new baseline
and the next real change has to beat it (this was observed: the single spurious
KEEP in 100 trials was followed by 60 discards). What it does not do is tell you
which of the night's KEEPs was the spurious one. `report` lists them; the diffs
are yours to read.

### 11. Platform and environment

**macOS** is the developed and measured platform: 250/250 tests pass, and every
timing in this README was taken there.

**Linux is correctness-verified only, in a container.** `swift:6.1`, `linux/arm64`
(aarch64), Swift 6.1.3, kernel 6.12.76-linuxkit, glibc 2.39. `swift build` rc=0,
`swift build --build-tests` rc=0, `swift test` **245 of 252**. All 7 failures are
the same `Package.resolved` cross-platform lockfile refusal described below, and
none is anything else.

**Not verified on Linux, and you should not assume it works:**

- **Real `perf` attachment.** No `perf` is installable for that container's
  kernel, so the refusal branch was reached with a stub. The `profile` path on
  Linux refuses loudly when `perf_event_paranoid` forbids sampling — that much is
  exercised; a successful `perf` sample is not.
- **Any Linux timing.** None exist, deliberately. Benchmarking in a VM on a Mac
  produces numbers this project would have to disown. No Linux performance number
  is published here because none was measured.
- **`baseline` and `eval` end to end**, blocked by the lockfile issue below.
- The malloc / instruction hint path.
- Non-container Linux, and x86_64 Linux. Everything above is one aarch64
  container on a Mac.
- An actually old glibc. The `posix_spawn` file-descriptor fallback is exercised
  by *forcing* it on glibc 2.39, not by running on 2.31.

**`Package.resolved` is not portable across platforms.** `ordo-one/benchmark`
resolves `malloc-interposer` on macOS and `package-jemalloc` on Linux, so a
lockfile committed on macOS cannot be `init`-ed on Linux and vice versa. If you
work on Linux, run `init` and `baseline` on Linux, with a lockfile resolved
there; do not carry a macOS lockfile over.

**The run claim is an advisory `flock` on an open file description, and advisory
locking is unreliable on network filesystems.** If your repository or your
`AUTOR3SEARCH_SWIFT_STATE_HOME` is on NFS, the "one eval per run at a time"
guarantee is not one.

**`profile`'s ranked table comes from `sample`, whose call graph is inclusive**,
so framework lines can outrank your own code at the top of the list. This is
documented rather than filtered — filtering would invent a rule the data does not
support.

**Laptops are noisy.** See [Why a rank test](#why-a-rank-test): one sample in
thirty landed 73% above the median on an otherwise quiet machine. `doctor` checks
Low Power Mode, power source, core counts and load average for that reason, and
you should read its warnings before trusting an unattended overnight run.

**`count` below 4 can never reach significance**; with two or more benchmarks,
neither can 4. `eval` warns when no KEEP is reachable at your `count` and tells
you what it would have to be.

### 12. `init` creates a commit in your repository

It commits exactly `.gitignore` and `Package.resolved` — and only whichever of
the two is untracked or modified. It stages by path, never `git add -A`. It
announces the SHA and the paths, states that nothing else was staged, and prints
`git reset --soft HEAD~1` to undo. It does **not** commit `config.yaml` or
`program.md`. A tool that makes a commit in someone else's repository should say
so before it is run, so: it does, and now you know.

### 13. A known residual TOCTOU in the frozen restore

There is a disclosed time-of-check-to-time-of-use window in the frozen-restore
path. A restore refusal is recorded as `frozen_restore_refused` *plus* a durable
`run.tainted` marker that makes every later `eval` refuse until a human deletes
it. `eval` never retries a refused restore — that no-retry rule is what caps an
attacker at roughly one attempt per run, with a logged alarm on every loss.

### And the one that is not the tool's fault

**Microbenchmarks are not your application.** Everything here optimizes the
benchmarks you declared. A benchmark that exercises a cold path, a trivial
helper, or a function nobody calls under load produces numbers that are entirely
real and entirely useless. Benchmark what dominates the workload you actually
care about — ideally informed by `autor3search-swift profile` rather than a
guess. `init` says the same thing when it refuses a repository with no
benchmarks.

---

## Building from source

```sh
swift build -c release
swift test
```

The test suite is 250 tests on macOS and takes several minutes: a good part of it
builds and measures the real fixture package with the real benchmark harness,
because the things worth testing here are the ones that only fail for real.

## Licence

MIT. See [LICENSE](LICENSE).

Gal Be &lt;galevgi@gmail.com&gt;
