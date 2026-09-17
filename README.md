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
repository's absolute path — **which moves them out of the agent's stated working
set, not out of its reach.** They are plain files owned by the same user; read
[the threat model](#boundary-2--the-harnesss-own-state-files-are-not-authenticated)
before you treat that as a security boundary.

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
# Delete every compiled artifact under .build before each side is built, so the
# measured binaries come only from sources the gates hashed. OFF by default: it
# roughly doubles the cost of an experiment (measured +33.6s on the demo package).
# Dependencies are not re-resolved either way -- this is a cold build, not a
# re-clone. See "The build cache is not verified" in the README.
purge_build_output: false
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
| `purge_build_output` | `false` | Delete every compiled artifact under `.build` before each side is built, so the measured binaries come only from sources the gates hashed. Off because it costs a measured **+33.6 s** per eval. Optional in the file: a `config.yaml` written before this key existed still loads, and still matches the SHA-256 `baseline` pinned for it. See [the build cache](#the-build-cache-is-not-verified). |

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

`eval --json`'s `reason` is a stable, machine-readable string. The full set is
in the gate table below; four are worth calling out because they are newer than
the rest and an agent loop keyed on the older ones will not recognise them:

| `reason` | What it means |
|---|---|
| `measured_binary_changed` | One of the four executables gate 8 launches changed its SHA-256 mid-measurement. The eval refuses, **both sides' measured binaries are deleted** so nothing poisoned survives into the next experiment, and the run is tainted until a human clears `run.tainted`. |
| `dependency_checkout_modified` | A file under `.build/checkouts/` does not match the revision `Package.resolved` pins. |
| `plugin_cache_not_purged` | `.build/plugins` could not be deleted. **Fail-closed**: a cache that cannot be discarded is a cache that will be reused. |
| `build_output_not_purged` | Same, for the wider purge under `purge_build_output`. Also fail-closed. |
| `baseline_predates_tree_inventory` | The baseline record was written before the out-of-scope inventory existed. Re-run `baseline` under a new tag; see [re-baselining](#re-baselining-is-required-after-upgrading). |

The two `*_not_purged` reasons are refusals, not warnings, and deliberately so:
the whole point of deleting an artifact nothing can hash is that it is *absent*,
and "we tried to delete it and could not" is indistinguishable from "it is still
there".

## The gate chain

`eval` runs the gates below in order. Gates 1 through 4 reject before anything is
built or measured — a `FAIL` from them costs seconds, not minutes.

| # | Gate | Rejects with |
|---|---|---|
| 1 | **Scope.** Every path changed between `frozenCommit` and `HEAD` must match a `scope` glob. Any change to `Package.swift` or `Package.resolved` is rejected outright, regardless of scope. | `out_of_scope`, `manifest_change_rejected` |
| 2 | **Config integrity.** SHA-256 of `.autor3search/config.yaml` must equal what `baseline` recorded. | `config_hash_mismatch` |
| 2a | **Manifest integrity, by hash.** `Package.swift` and `Package.resolved` *as they are on disk*, plus every manifest in the recorded inventory (nested `Sub/Package.swift`, `Package@swift-6.0.swift`, anything under `.swiftpm/`), must hash to what `baseline` recorded — and a manifest *appearing* where baseline recorded none is itself a mismatch. | `manifest_change_rejected`, `baseline_predates_manifest_inventory` |
| 2b | **Clean working tree**, read with `git status --porcelain --ignored` — ignored files included, because plain `--porcelain` omits them and a planted gitignored source compiles and is measured. `eval` builds and measures the *working tree*, while gate 1 inspects *commits*. Ignored files are **recorded at baseline, not banned**: one that was already there is part of the honest starting point, and only one that **appears, changes or disappears after the freeze** is refused — the pinned worktree is a checkout of a *commit* and can never contain it, so it exists on the candidate side alone. The harness's own outputs (`.build/`, `results.tsv`, `run.log`, `.autor3search/profiles/`) are excluded; they change every eval by design. **Tracked files are additionally hashed against the commit's own blob ids**, because a `filter.<name>.clean` driver can make `git status` report a modified file as clean — so this gate no longer takes git's word for it. | `dirty_working_tree` |
| 2c | **Out-of-scope files, by content.** Hashes every file outside `scope` *except* `.git/`, `.build/` and the harness's own outputs (`results.tsv`, `run.log`, `.autor3search/profiles/`); refuses any modified, missing or extra. Gate 1 asks git what changed; gate 2c asks the disk. | `out_of_scope`, `baseline_predates_tree_inventory` |
| 2d | **Dependency checkouts.** Every file under `.build/checkouts/` is verified per dependency against the revisions `Package.resolved` pins. A *wholly missing* checkout is allowed — SwiftPM re-clones it from that same pin. | `dependency_checkout_modified` |
| 3 | **Restore frozen files.** Every file in every frozen test and benchmark target is restored from the snapshot, byte for byte, after the whole stored manifest has been verified against the recorded hashes. | `frozen_restore_refused` |
| 4 | **Reject new files** appearing in any frozen target directory. | `new_test_or_benchmark_file` |
| 4b | **Discard the caches no inventory can vouch for.** `.build/plugins` is deleted before every build, on both sides, always: a build-tool plugin is *executed* during the build, and llbuild will reuse a cached one whose sources did not change. `purge_build_output: true` deletes the rest of the build output too. | `plugin_cache_not_purged`, `build_output_not_purged` |
| 5 | **Release build.** `swift build -c release`, plus the benchmark target and `BenchmarkTool` by name. | `build_failed`, `build_timed_out` |
| 6 | **Tests.** `swift test` — which builds and runs in **debug**, while everything measured is **release**. See [limitation 9](#9-gate-6-tests-a-debug-build-the-binary-that-is-measured-and-kept-is-release). | `tests_failed`, `tests_timed_out` |
| 7 | **Worktree integrity.** Checks the pinned worktree is at `measurementCommit` and that git reports it clean, then **restores it unconditionally** before the baseline-side build — clearing any `--assume-unchanged`/`--skip-worktree` flags first, in *separate* `update-index` calls (both in one call exits 0 and does nothing; a forced checkout does not undo `--skip-worktree`). Flags are re-read **after** the checkout, not only before, and contents are then verified by hashing every file against the blob ids the commit records, **not** by asking `git status` — a `.gitattributes` filter driver can make `git status` report a rewritten file as unchanged. Restoring rather than refusing is deliberate: the correct contents are known exactly, and refusing would let one `touch` stop every experiment. Cleared flags surface as a warning; a restore that cannot complete is `worktree_integrity`. | `worktree_integrity` |
| 8 | **Measure.** Interleaved, `count` rounds per side, baseline and candidate alternating, one discarded warm-up sample per side. | — |
| 9 | **Score.** The three-part rule below. | `no_significant_improvement`, `improvement_below_min_effect`, `significant_regression` |

**Gates 2a and 2c exist because git's view of a repository is not the disk, and
the adversary owns git's view.** Gate 1 derives what changed from
`git diff --name-only`; `swift build` compiles what is on the filesystem. Every
way of separating those two is a bypass, and three were demonstrated: an ignored
file git does not list, an `.git/info/exclude` rule with no repository file at
all, and `git update-index --assume-unchanged` on a tracked file so git keeps
reporting the old bytes. So the path-based checks are now a **first-line
filter**, not the boundary. The boundary is content: gate 2a hashes every
manifest on disk, gate 2c hashes every file outside `scope`, and gate 2b reads
the ignored set as well as the untracked one. **A hash cannot be talked out of
noticing.**

`scope` still says what the agent may change. It is no longer asked to say what
*did* change.

**What the three content gates cover between them**, stated as coverage rather
than as three separate claims:

- **Gate 2c** hashes every file outside `scope` except `.git/`, `.build/` and
  the harness's own outputs, refusing any modified, missing or extra.
- **Gate 2b** covers `.build/`'s exemption for files git can see: anything
  uncommitted, and any *ignored* file added, modified or removed since baseline.
- **Gate 2d** covers the compiled part of what both exempt: every file under
  `.build/checkouts/`, verified per dependency against the revisions
  `Package.resolved` pins, a wholly-missing checkout allowed because SwiftPM
  re-clones it from that pin.

What remains unhashed is `.build`'s build **output** — `out/`, `plugins/`,
`repositories/`, `artifacts/` — derived from inputs all three gates verify, and
rebuilt by gate 5. See
[the build cache](#the-build-cache-is-not-verified) for what that leaves open.

### Two checks that do not depend on any list being complete

Read this before the enumeration below, because it is the reason the tool is
shippable despite that enumeration being incomplete and *known* to be
incomplete.

Most of the hardening in this README is a list: of exempt regions, of config keys
that execute programs, of environment variables. **Every such list is one attack
behind by construction.** Two changes are not lists, and between them they
neutralise whole classes rather than instances:

1. **The measured-binary hash is snapshotted immediately after the last build.**
   Everything that runs afterwards — `isClean`, a possible worktree repoint, the
   unsafe scan's `git show` — is downstream of it, so anything those steps change
   is a *mismatch the guard reports* rather than a value it adopts. In the
   implementer's words: **a snapshot whose correctness depends on a denial list
   being complete is a snapshot in the wrong place.** That placement alone blocks
   the `core.fsmonitor` attack below *even with `core.fsmonitor` undenied*.
2. **Content is hashed against the commit's blob ids, never asked of git.**
   Both the pinned worktree and the candidate's tracked files are checked that
   way. No filter, attribute, or config participates. So the entire class of *"git
   was configured to lie about what changed"* is caught **by effect, regardless of
   mechanism** — including mechanisms nobody has thought of yet.

The rule generalising both: **prefer a check whose correctness does not depend on
an enumeration you maintain.** Where you cannot have one, keep the list — but
know what it is worth.

### Every exemption from an integrity check is a candidate bypass

This is the most transferable thing in the project, and it is worth more than
any individual gate above.

**Fifteen bypasses have been found across seven reviews — thirteen closed, two
open and named — and the later ones all came from regions that had been
*exempted* from a check for good reasons** — `.build/` because hashing it is
expensive, the pinned worktree because it is the harness's own, `.git/` because
git never reports it and it is not source. Every one of those exemptions was
defensible when it was made. Every one of them was a hole.

If you extend this tool, the question to ask of an exempt region is not *"is this
ours?"* or *"is this expensive?"*. It is **three** questions, and each of the
last two was learned only after something got through:

> **Does the compiler read it?**
> **Does the harness run it?**
> **Is it still running while you measure?**

The first question found most of them — planted sources git had been taught not
to report, an out-of-scope helper hidden with `--assume-unchanged`,
`.build/checkouts` (SwiftPM's, and the dependency *source* that gets compiled),
`.build/plugins` (SwiftPM's, and *executed* during the build), the pinned
worktree (the harness's, and one of the two binaries being timed). Ownership was
never the right test.

**The second question found the last three, and none of them is code the
compiler ever sees.** The harness's own `git checkout --detach --force` executes
a `post-checkout` hook out of `.git/hooks` — a directory shared with every linked
worktree — which undid the very repair the checkout had just performed. The same
`git checkout` executes `.gitattributes` **filter drivers**. And a
`DYLD_INSERT_LIBRARIES` dylib, injected through an inherited environment
variable, ran inside the measurement itself. A tool that shells out is a tool
that runs code it did not write, at every one of those call sites.

**The third question found the eleventh, and it is the one that took longest to
see, because the answer was in front of us the whole time: *the code you are
measuring is running while you measure it.*** Gate 7 verified the pinned
worktree, restored it, and built it — and then never looked again. The agent's
benchmark waited until the harness launched it and rewrote the baseline side
*afterwards*. Every gate had passed. Every gate had passed **before the adversary
started**.

> **A check that runs before the adversary does is a check the adversary can
> invalidate.** The fix was not a better check; it was the same check, run before
> every sample instead of once.

This generalises well past benchmarking. Anything that validates an input and
then hands it to something that keeps executing has this shape — and the
attacker's move is always the same, which is to be quiet until after the
validation and loud afterwards.

Three further principles came out of fixing all this, all of which generalise
past this project:

**Sample a post-condition AFTER the last thing that could change it.** Gate 7
read its index flags *before* the checkout, and the hook re-set them *after* —
so the warning was not wrong, it was **empty**, which is worse. A check that runs
before the adversary's last move reports on a world that no longer exists.

**A check placed before the repair that fixes what it refuses over will brick the
run, not protect it.** Gate 7 used to refuse on a `verify` that ran *before* the
restore whose whole job was to repair what the verify had refused over — so
anything `git status` could see was permanently fatal: that eval and every eval
after it returned `worktree_integrity`, with the worktree never repaired. One
stray `touch` could stop a night's work. It now **restores first and verifies
afterwards**, which is correct precisely because the worktree's right contents
are known exactly, so repairing is always the right move.

**A fallback that has never run is not a fallback.** The session-isolation spawn
carries a fallback for libcs that reject the flag. It was placed at the
`posix_spawn` call — and glibc validates the flag mask inside
`posix_spawnattr_setflags` and returns `EINVAL` *there*, before `posix_spawn` is
ever reached. So on the one libc the fallback existed for, it could never have
run; the refusal became a thrown error instead. Darwin defers the check to the
spawn, so the same code took a different door on each platform. It now triggers
on **any** failure rather than on one errno, because keying on `EINVAL` fires on
one libc and not the other. This was found by *running* Linux, not by reading the
code — which is the same lesson as the paragraph above, arriving from the
opposite direction.

**Deny, do not delete.** Hooks are disabled with `-c core.hooksPath=/dev/null` on
every git invocation the harness makes, and a command-line `-c` outranks every
other configuration source. Emptying or verifying `.git/hooks` would have
achieved nothing: the same hook can be delivered entirely through
`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0=core.hooksPath`, with nothing written under
`.git/` at all. `/dev/null` rather than an empty directory the harness creates,
too — an empty directory is same-uid and can simply have hooks written into it,
whereas `<path>/post-checkout` under `/dev/null` cannot resolve.

### The environment is filtered, by allowlist

Harness subprocesses **no longer inherit the environment**. They get exactly:

```
PATH  HOME  TMPDIR  USER  LOGNAME  SHELL
LANG  LC_ALL  LC_CTYPE  TERM  __CF_USER_TEXT_ENCODING
```

One list, applied to `swift build`, `swift test`, `swift package describe`,
`swift package resolve`, every `git` call, and the `BenchmarkTool` invocation
that does the measuring. Dropped, among everything else: `SWIFT_EXEC`,
`SWIFTPM_*`, `TOOLCHAINS`, `DEVELOPER_DIR`, `SDKROOT`, `CC`, `CXX`, `CFLAGS`,
`LDFLAGS`, `DYLD_*`, `LD_LIBRARY_PATH`, and every `GIT_*`.

**Allowlist, not denylist, and the reason is short:** a denylist has to track the
variables of two separately evolving tools — git alone added `GIT_CONFIG_COUNT`
in 2.31 — and when it falls behind it fails **silently**. An allowlist fails
loudly: the symptom is a tool that cannot find something, immediately.

The measurement gets the same filtered set for a second reason that has nothing
to do with tampering: **exchangeability**. The two sides must differ in exactly
one thing, the commit. Anything inherited that reaches one invocation and not the
other, or varies between them, breaks that before an adversary is involved.

> **BEHAVIOUR CHANGE.** `TOOLCHAINS` and `DEVELOPER_DIR` no longer reach the
> build. If you select a non-default toolchain that way, `eval` will not honour
> it — use `xcode-select`, or put the toolchain on `PATH`. A per-process
> toolchain override is precisely the side-discriminating primitive this closes,
> so it could not be kept.

**`PATH` is allowed, and it is a residual.** It is adversary-influenced.
`/usr/bin/git` and `/usr/bin/swift` are invoked by *absolute* path, so the
harness's own entry points do not depend on it — but a package whose build shells
out to a bare command name can still be pointed at a wrapper. Normalising `PATH`
to a fixed value would break toolchains installed outside the default prefixes,
so it is allowed deliberately and recorded here rather than silently trusted.

**`.gitattributes` filter drivers are a residual with an honest status.** A
`smudge`/`clean` pair makes the worktree hold one thing while the commit holds
another *and* `git status` reports clean — measured standalone: worktree
`count = 17500` against a commit recording `1750`, `git status --porcelain`
empty, `git hash-object --no-filters` giving `f0b02a86` against the blob
`cc57109a`. Gate 7 answers it by hashing contents against the commit's blob ids
instead of asking git. But the end-to-end variant **could not be landed in a
linked worktree** — the clean filter did not hide the modification there, so the
pre-restore check refused first, on the old binary too. So the content hashing is
**defence in depth, not a measured closure**, and this README will not call it
one.

### Git config that runs programs: what is denied, and what cannot be

`core.hooksPath` was never the only key that makes git execute something. Every
git call the harness makes now denies **twenty** keys, taken from `git config`'s
documentation for the installed version (git 2.54.0) rather than from the attacks
already found, and each one checked against the commands this harness actually
runs:

```
core.hooksPath          core.fsmonitor          core.alternateRefsCommand
core.sshCommand         core.gitProxy           core.askPass
credential.helper       core.pager              core.editor
sequence.editor         diff.external           interactive.diffFilter
gpg.program             gpg.openpgp.program     gpg.x509.program
gpg.ssh.program         gpg.ssh.defaultKeyCommand
gc.recentObjectsHook    uploadpack.packObjectsHook
core.attributesFile     core.excludesFile
```

The last two do not execute anything themselves; they are the *out-of-tree door*
to the filter and ignore machinery that does.

> **CANNOT BE DENIED, and this is a live residual rather than a theoretical one.**
> `git -c` takes no wildcard, and these keys are per-name:
>
> `filter.<name>.clean` · `filter.<name>.smudge` · `filter.<name>.process` ·
> `diff.<name>.textconv` · `diff.<name>.command` · `pager.<cmd>` ·
> `trailer.<key>.cmd` · and the `difftool` / `mergetool` / `guitool` / `man` /
> `browser` `<tool>.cmd` families.
>
> Enumerating the names out of the repository's own config would be a
> check-then-use race — the same agent can add one afterwards. So the honest
> statement is precise and narrower than "closed": **the content consequence is
> closed; the execution is not.** A `diff.<name>.textconv` still *runs* during a
> harness git call. What it can no longer do is change what the harness concludes
> about file contents, because that conclusion is now reached by hashing against
> blob ids rather than by asking git.

**The denial list will go stale, and that is survivable.** It is tied to git's
release cadence, and the last vector found was found by the implementer
deliberately attacking *its own stated gap* — the undeniable `filter.<name>` family
— and succeeding. That cuts both ways, and both halves belong here: it is evidence
the enumeration method **works**, and it is evidence that **a sixteenth of this
shape is likely**. A reader deciding whether to trust this deserves both. The
reason it is survivable rather than fatal is
[the two checks above](#two-checks-that-do-not-depend-on-any-list-being-complete),
which do not depend on the list being complete — the `core.fsmonitor` attack was
blocked by the snapshot's *placement* as well as by its key being denied, and the
clean-filter attack was closed by content hashing rather than by naming the
filter.

**The honest-repo cost, because you will notice it.** `core.fsmonitor` is a
genuine performance feature on large repositories. It is now denied **inside the
harness's own git calls only** — you keep it everywhere else and lose the speedup
during `eval`. That is correct rather than regrettable: the harness cannot tell a
real fsmonitor from an agent's. The same applies to `core.pager`, `core.editor`
and `credential.helper`. No honest-path regression was observed, but on a large
repository this is a real cost and it should be read here rather than discovered.

### What did *not* work, which is also a result

Two negative results, recorded because they tell you what the threat actually
requires rather than what it is imagined to require.

**A `SWIFT_EXEC` compiler wrapper could not be made to run.** SwiftPM resolves
`libSwiftScan` and every sibling tool *relative to `SWIFT_EXEC`'s directory*, so a
wrapper placed outside the toolchain fails manifest compilation with
`Invalid manifest`; mirroring the toolchain with symlinks got as far as
`tests_failed`. The variable is dropped from the allowlist anyway — but the class
is **not** claimed closed by a test that was never made to pass.

**A `DYLD_INSERT_LIBRARIES` variant did work**, and is closed. A dylib that read
its own executable path and spawned spinner threads only when that path lay under
`baseline-worktree` doubled the baseline side: **ratio 0.47999**, baseline
7 473 151 ns against candidate 3 587 071 ns, on a commit whose only change was two
lines of comment. With the environment filtered, the same attack reads
**0.99915**. The most useful detail: a first attempt that burned CPU only in the
dylib's *constructor* did not skew anything (ratio 0.994). The benchmark library
times its own inner loop, so **the skew has to persist through the measured
region** — a load-time-only injection is not the attack.

Gate 3's snapshot and restore both `lstat` every path. A symlinked file is
refused at snapshot time and at restore time, loudly, rather than written
through; paths are normalized and rejected if absolute or containing `..`.
Without that, an agent that plants a symlink mid-run converts an unattended
restore into an arbitrary-file-overwrite primitive on your machine. Restore also
verifies every stored file against the hash the baseline manifest recorded, as a
separate pass over the whole manifest before the first byte is written — so a
tampered file discovered halfway through cannot leave the first half of the
frozen set already restored from a source the harness does not trust.

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
| Measure an uncommitted edit | Gate 2b reads `git status --porcelain --ignored`, so it sees ignored files as well as untracked ones. |
| Plant a source file that a `.gitignore` rule hides from `git status` | Gate 2b, against an ignored-file inventory taken at baseline: a file that **appears or changes after the freeze** is refused. Plain `--porcelain` omits ignored files, and a committed `Sources/Demo/.gitignore` containing `*.gen.swift` is an in-scope, non-manifest change gate 1 waves through — measured, that bought `keep` at ratio 0.11298 on a planted file. `.git/info/exclude` does the same with no repository file at all, and is caught the same way. |
| Hide a change to an **out-of-scope** file from git (`--assume-unchanged`) | **Gate 2c**, an on-disk inventory of every file outside `scope`, hashed at baseline and re-walked every eval. Gate 1 could not: it asks git what changed, and the agent owns git's view of its own repository. Measured before the fix: a **comment-only** commit returning `keep`, rc 0, **ratio 0.000737**, because an out-of-scope benchmark helper's `repeatCount` had been edited from 1750 to 1 behind git's back. |
| Tamper with the **stored** frozen files | Gate 3 verifies every file in the store against the SHA-256 the baseline manifest recorded, across the whole manifest, before writing a byte. Measured before the fix: one `sed -i` on the stored benchmark made `eval` install it into the repository and then measure it — `keep`, rc 0, **ratio 0.000717**. |
| Tamper with `baseline.json` or `frozen-manifest.json` themselves | **Nothing.** They are unauthenticated JSON, same directory, same uid. This is the stated boundary, not an oversight — see [the threat model](#boundary-2--the-harnesss-own-state-files-are-not-authenticated). |
| Swap a frozen file for a symlink so the restore overwrites something else | Gate 3 refuses, records `frozen_restore_refused`, and taints the run so every later eval refuses until a human clears it. |
| Plant a `post-checkout` hook that undoes the harness's own repair | Every git invocation the harness makes is prefixed `-c core.hooksPath=/dev/null`, which outranks every other configuration source. `.git/hooks` is shared with every linked worktree and the restore's own `checkout --force` fired it. Measured before the fix: `keep`, rc 0, **ratio 0.10045**, with the worktree helper left at `175000` afterwards. |
| Deliver that hook through `GIT_CONFIG_COUNT` instead, writing nothing under `.git/` | Same denial — which is why the fix is *deny*, not *delete*. Measured before: `keep`, rc 0, **ratio 0.09985**. |
| Inject a dylib that slows only the baseline side (`DYLD_INSERT_LIBRARIES`) | Subprocesses no longer inherit the environment; an eleven-name allowlist replaces it. Measured before the fix: `keep`, rc 0, **ratio 0.47999** (baseline 7 473 151 ns, candidate 3 587 071 ns). After: **0.99915**. |
| Rewrite the worktree through a `.gitattributes` filter driver so `git status` still reports clean | Gate 7 hashes contents against the commit's blob ids rather than asking git. **Defence in depth, not a measured closure** — see [the residual](#the-environment-is-filtered-by-allowlist). |
| Have the agent's own benchmark rewrite and rebuild the baseline side *after* every gate has passed | The SHA-256 of all four measured executables is re-checked **before every sample**; a mismatch is `measured_binary_changed`, both sides' binaries are deleted, and the run is tainted. Measured before the fix: an in-scope commit whose `countWords` was byte-for-byte the original returned `keep`, rc 0, **ratio 0.04973** — and the *next* honest eval inherited the inflated binary for a second unearned KEEP at **0.05069**. |
| Spawn a process that burns CPU through the baseline samples, changing no bytes | Every spawned child gets **its own session** (`POSIX_SPAWN_SETSID`), and each subprocess run ends by sweeping that session — a process cannot leave a session with `setpgid`, which is how the first version of this was escaped. Measured before: **3/3 KEEP**, ratios 0.54935 / 0.56069 / 0.56485, twelve processes still alive each time. After: **3/3 discard**, 1.02742 / 1.02021 / 1.02803, **0 alive**. |
| …but have the benchmark call `setsid()` for itself first | **Not closed.** A process that creates its own session is not in the one being swept. See [the residual](#boundary-1--the-agents-benchmark-runs-unsandboxed). |
| Run the machine hot during the candidate's own sample so the baseline sample that follows is throttled | **Not closed, and not measured.** Nothing is spawned, written, or changed; the state is left in the silicon. See [the thirteenth](#boundary-1--the-agents-benchmark-runs-unsandboxed). |
| Point `core.fsmonitor` at a program that swaps the baseline binary during the harness's own `git status` | Every git call the harness makes denies **twenty** config keys that name a program, `core.fsmonitor` among them — *and*, independently, the binary-hash snapshot moved to immediately after the last build, so those `git` calls are downstream of it. Measured before: **3/3 KEEP** at 0.05014 / 0.04957 / 0.05013, baselines ~72 ms, the fsmonitor firing **11× per eval** and swapping the binary every time. After: **3/3 discard** at 1.00028 / 1.00650 / 1.01029, baselines ~3.6 ms, fired **0×**. |
| Commit `.gitattributes` with a `clean` filter that always emits the committed bytes, and leave the fast code uncommitted in the working tree | Gate 2b no longer asks git whether tracked files changed — it hashes them against the commit's own blob ids. Measured before: `git status --porcelain` empty, the only commit a `.gitattributes`, **`rc 0`, `keep`, ratio 0.11637**. After: `rc 2`, `dirty_working_tree`, `k 0`. |
| Coast on an earlier win | The measurement point advances on KEEP. See [The two commits](#the-two-commits). |
| Conditionally skip a test from optimizable code | `doctor` scans for `.enabled(if:)`, `.disabled(if:)`, `XCTSkip` and `ConditionTrait`, in test targets *and* in non-test sources. **This one is not closed.** See [limitation 1](#1-gate-6-runs-your-tests-and-that-is-the-softest-link-in-the-chain). |
| Gut a function and forge the comparison its frozen assertion uses | `doctor` warns when in-scope code declares `==`, `!=`, `<`, `<=`, `>`, `>=` or `~=` for operand types that are *already* comparable in the standard library — a redeclaration, not a conformance. **This one is not closed either**, and the gutted function on the other side of the assertion is not detectable at all. See [limitation 1](#1-gate-6-runs-your-tests-and-that-is-the-softest-link-in-the-chain). |

## What the harness does not defend against

There are **two** boundaries here, and they are not the same kind of thing. One
is defended by **detection**; the other is not defended at all. An earlier
version of this README ran them together into a single sentence — *"the harness
defends against an agent that edits the repository, not against one that edits
the harness's own state"* — and that sentence was **false**, demonstrated false
by an attack that came straight through the channel it claimed was defended. It
is replaced below by two statements that are each true on their own terms.

### Boundary 1 — the agent's benchmark runs unsandboxed

**The agent's benchmark runs unsandboxed.** `eval` compiles and executes code the
agent wrote, as the same user, with no sandbox, on a filesystem containing the
pinned baseline worktree and the harness's own state. It can do anything that
user can do. `autor3search-swift` does not prevent that; it **detects the part
that would change a verdict.** The SHA-256 of all four executables the
measurement launches — the benchmark and `BenchmarkTool`, on both sides — is
recorded before measurement begins and re-checked before **every sample**, so a
benchmark that rewrites or rebuilds either side's binary is refused
(`measured_binary_changed`) before the next sample is taken, both sides' binaries
are deleted so nothing poisoned survives into the next experiment, and the run is
tainted until a human clears it. What remains undetected is anything that changes
a measurement without changing those bytes. The remedy for that is operational:
run the harness where the agent's code cannot reach the baseline, or under a
sandbox.

**Processes that outlive their sample are handled; one form of them is not.**
A benchmark that spawns a CPU burner leaves it competing with the *baseline*
sample that follows, and no byte changes, so the hash guard cannot see it. Every
spawned child therefore gets **its own session** (`POSIX_SPAWN_SETSID`), and each
subprocess run ends by sweeping that session — not merely its process group,
because a process leaves a group with one `setpgid` and Foundation's `Process`
does exactly that for every child it spawns, which is how the first version of
this was escaped. Measured before the fix, three runs of each form: the
`Process`-spawned burners returned **3/3 KEEP** — ratios 0.54935, 0.56069,
0.56485 — with **twelve processes still alive** after each eval. After: **3/3
discard** at 1.02742, 1.02021, 1.02803, **0 alive**, and a second honest eval
clean every time.

> One line about how that was nearly mis-recorded. An earlier round measured the
> same escape as landing only **1 in 3**, and wrote it down that way. That was
> noise from building concurrently with the measurement; run clean it is **3/3**.
> The correction *raises* the severity — the escape was reliable, not occasional
> — and it is the reason this README reports three runs of each form rather than
> one. **A single run is not a measurement.**

> **STILL OPEN: an explicit `setsid()` call by the benchmark escapes the sweep.**
> The sweep kills the session the harness created for that child; a process that
> calls `setsid()` for itself is in a *different* session and is not in the set
> being swept. This is a deliberate, unusual call rather than the default API —
> which is precisely why closing the default-API form mattered, since that was
> the version anyone would write by accident or by reaching for `Process` — but
> it is **not closed**, and nothing above should be read as implying otherwise.

**THE THIRTEENTH, named and unmeasured: thermal and frequency skew.** A candidate
benchmark can run the machine hot during its own sample, or hold a wide SIMD/AMX
loop, so that the *baseline* sample which follows executes at a throttled clock.
On Apple silicon the reverse is plausible too — parking work so the scheduler
moves the following sample onto E-cores. It spawns nothing, writes nothing,
changes no bytes, and needs no process to survive: **the state it leaves is in
the silicon, not the process table**, so neither the session sweep nor the
per-sample binary hash can see it, and neither could any extension of them.

**Nobody has established whether the effect is large enough to flip a verdict.**
It is named here because a reader deserves to know it exists, not because it has
been quantified — no measurement of it appears in this project's run log, and
this README will not imply one. The defences are operational: idle-gap pacing
between samples, or a dedicated machine. Interleaving already cancels *slow*
drift across a run (see [Why a rank test](#why-a-rank-test)); it does not cancel
a skew deliberately timed to land on one side.

**The attack that forced this, because it is worth knowing what it looked like.**
One in-scope commit. `countWords` kept the *original quadratic algorithm* — not
one instruction faster — plus a lazily-initialised global that fired when the
harness launched the candidate `Bench` process, rewriting the pinned worktree's
benchmark to 35 000 repeats and rebuilding it there. **`rc 0`, `keep`, ratio
0.04973**, warnings empty, baseline 73 302 015 ns against candidate 3 645 439 ns.
On KEEP, gate 7 restored the worktree source, so the trace vanished — and the
*next*, entirely honest eval inherited the inflated binary and earned a second
unearned KEEP at ratio 0.05069. That is the stale-baseline coasting bug this
project exists to prevent, reintroduced through a side door.

Two details from building it are worth more than the attack itself. A naive
version with no guard was **caught** — `worktree_integrity` — because `swift
test` imports `Demo` and calls `countWords`, firing the sabotage before gate 7
looked. The working version gated on
`ProcessInfo.processInfo.processName == "Bench"` so the write landed strictly
*after* gate 7 had verified, restored and built. **The vector was TOCTOU against
gate 7, not "the worktree is writable."** And detection alone was not enough: the
poisoned binary had to be *deleted*, or the next honest eval inherits it.

Per-sample rather than once, and that interval was chosen against three attacks
rather than by taste: a check only at the end loses to
sabotage-measure-restore; a check only at the start loses to this attack; and
because `MeasureSession` interleaves the two sides *within* every round, even a
check after the last candidate sample leaves nine rounds unguarded. The cost is
**130 ms per eval — 0.33%** of a ~39 s experiment, so no compromise was needed.

### Boundary 2 — the harness's own state files are not authenticated

This one is different in kind: **there is no detection here, and no cheap fix.**

The frozen snapshot, the baseline record and the pinned worktree live under
`~/Library/Caches/autor3search-swift/…` (or `AUTOR3SEARCH_SWIFT_STATE_HOME`).
They are **plain files, mode `0644`, owned by the same user as the agent**.
Being outside the repository puts them outside the *scope gate* — nothing more.

One hole here has been closed. `FrozenSnapshot.restore` used to copy stored bytes
into your repository without ever comparing them to the SHA-256 the baseline
manifest had already recorded for them, so a single `sed -i` on the *stored*
benchmark made `eval` install the attacker's benchmark into the repository and
then measure it — **rc 0, `keep`, ratio 0.000717**, on a benchmark the repository
itself never contained. Restore now verifies the whole manifest against the
recorded hashes *before writing a single byte*, and refuses with
`frozen_restore_refused`.

**What that does not close, and cannot be closed cheaply:**

- `frozen-manifest.json` holds the very hashes that check compares against, in
  the same directory, same user, same mode. An attacker who edits the stored file
  **and** its recorded hash passes.
- `baseline.json` is plain JSON in the same place. Editing `measurementCommit`
  back to `frozenCommit` reproduces the coasting bug outright — every later no-op
  scored against the run's original slow binary.

**Why there is no cheap fix.** Any MAC needs a key the attacker cannot read, and
the attacker runs as the same uid with a shell. A key stored beside the data is
readable; a key derived from the data is forgeable; a self-hash is theatre. The
same process can also rewrite the tool's own binary, the toolchain, and the
`.build` directory it measures. There is no version of this that is solved in
software on the agent's own account.

**The real fixes are operational, and they are the operator's job.** If the
assumption above is wrong for your deployment — if the agent is genuinely
untrusted rather than merely fallible — run the harness under a **different
uid**, or make the state root **read-only to the agent's uid**, and point
`AUTOR3SEARCH_SWIFT_STATE_HOME` at it. The harness will not do this for you and
does not pretend to.

**The difference between the two boundaries, in one line.** Boundary 1 is
*defended by detection*: the attack is possible, it is noticed, and the run
refuses and cleans up after itself. Boundary 2 is *not defended*: state-file
tampering would simply work, and the only answer is to put the files somewhere
the agent cannot write. Do not read the first as covering the second.

So: run this against code you are willing to have compiled and executed, in a
directory you are willing to have written to, by an agent you are supervising to
the degree the work deserves. What the gates give you is that **the commit that
gets kept is the commit that was measured**, on criteria that did not move while
it was measured. That is a real property, and it is narrower than it sounds.

### The build cache is not verified

**The build cache is not verified.** An agent that can write into `.build/` can
put code into the measured binary that no gate hashed: llbuild decides what to
rebuild from recorded input signatures, so a poisoned object file or linked
binary under `.build/out`, belonging to a module whose sources did not change, is
reused rather than recompiled. `autor3search-swift` deletes the compiled
build-tool plugins (`.build/plugins`) before every build, because those are
executed rather than merely linked and the deletion costs about 0.8 s per side;
it does not delete the rest, which measured ~18 s per side and would roughly
double the cost of every experiment. Set `purge_build_output` to have every
artifact rebuilt from verified sources, at that cost. The real remedy is
operational: run the harness where the agent cannot write `.build`.

The plugin deletion is **unconditional and is already in the price** you see:
measured at 1.673 / 1.677 / 1.845 s per side with the plugins kept against
2.527 / 2.478 / 2.491 s with them deleted — **+1.62 s per eval, about 4%** of a
~39 s experiment. Turning on `purge_build_output` adds a further **+33.6 s** end
to end. Dependency checkouts survive both deletions, so either way this is a cold
*build*, not a re-resolve: nothing is re-cloned and no network is touched.

```yaml
# .autor3search/config.yaml
purge_build_output: true
```

Also available as `AUTOR3SEARCH_SWIFT_PURGE_BUILD_OUTPUT=1` in the environment,
which ORs with the config key. That override exists because `config.yaml`'s bytes
are pinned at baseline, so editing it mid-run means re-baselining and discarding
the run's history — and this switch, unlike `alpha` or `scope`, changes nothing
about how a result is *judged*, only how trustworthy the artifact being judged
is. **It can only turn the purge on.** No value of it disables anything, which is
what makes it safe to read from an environment the measured agent may own.

**`.build/artifacts` is a second, narrower residual.** It is empty for any
package without a `binaryTarget`, but a package that has one gets an
`.artifactbundle` extracted there, and a plugin may execute what is inside.
SwiftPM checksum-verifies the bundle when it *downloads* it, against a checksum
declared in `Package.swift` — which gate 2a hashes — but the **extracted copy is
not re-verified on each build**. `purge_build_output` does not cover it either;
the purge deliberately spares `artifacts/` so that turning it on does not force a
re-download. **No fixture exercises this path.** It is documented rather than
tested, and that asymmetry is stated here rather than left for someone to
discover: every other claim in this section has a test behind it, and this one
has an argument.

### Repository layouts this is stricter about than you may expect

The hardening above is not free, and the cost is not only the `.build/out`
rebuild. Gate 2c hashes **every file outside `scope`** except `.git/`, `.build/`
and the harness's own outputs — and *"every file"* includes **gitignored ones**.
That is deliberate: an exemption is a candidate bypass, and gitignored files are
exactly where two of the demonstrated attacks lived. But it means three ordinary
repository layouts will produce refusals that are correct by the rule and
surprising in practice.

| Layout | What you will see | Why |
|---|---|---|
| A large **gitignored vendored directory** outside `scope` | It is re-hashed on **every eval**, and any legitimate change to it gives `out_of_scope` | Gitignored is not exempt; only `.git/`, `.build/` and harness output are |
| A **monorepo or nested package** | A change to *any* nested `Package.swift` anywhere in the tree gives `manifest_change_rejected` | Gate 2a's inventory covers nested manifests, by design, and never refreshes on KEEP |
| **Submodules** | `git submodule update` changes inventoried files and gives `out_of_scope` | The submodule's working files are outside `scope`, so they are inventoried like any other file |

**The remedy in all three cases is the same: re-baseline under a new tag after
the legitimate change.** The inventory is recorded at `frozenCommit` and
deliberately never advances — that is what makes it a fixed reference — so a
genuine change to anything it covers requires a new reference.

**None of this affects the normal single-package flow**, which is what `init`
generates and what the fixture exercises: a comment-only commit still discards
and a real optimization still reaches KEEP (measured after the last round of
hardening at ratio **0.11265**). If your repository has one of the layouts above,
expect the friction and budget for the re-baseline; it is accepted cost, not an
undiscovered bug.

### Re-baselining is required after upgrading

A `baseline.json` written before the out-of-scope tree inventory existed has no
`treeSHA256`, and `eval` refuses it with **`baseline_predates_tree_inventory`**
rather than skipping the check. Run `baseline` again under a new tag.

That refusal is deliberate and is the same rule as
`baseline_predates_manifest_inventory`: *"there is no record"* must never be
allowed to read as *"there is nothing to check"*. Silently accepting an old
record would restore exactly the hole the inventory closes. It is stated here
because an upgrade that starts refusing every eval is an unpleasant surprise to
diagnose from the reason string alone.

## Scoring

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

> **These 200 trials were run at the PREVIOUS defaults — `alpha: 0.05`,
> `min_effect_pct: 1.0`.** They are not a measurement of what ships today.
> **No false-KEEP rate has been measured at the current defaults**
> (`alpha: 0.005`, `min_effect_pct: 3.0`). Read every figure in this section
> with that attached.

| Arm (at `alpha: 0.05`, `min_effect_pct: 1.0` — the **old** defaults) | Scale | Spurious KEEPs | 95% Clopper-Pearson CI |
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

**What today's defaults would have done to that one false KEEP.** Arm B's
`p = 0.03546` does not clear `alpha = 0.005`, and its `ratio 0.98853` — a 1.15%
"win" — does not clear a 3.0% effect floor either. Both criteria reject it, and
independently. The same is true of arm A's two near-misses (`p 0.03546` and
`p 0.02881`, both above 0.005).

**That is an argument, not a measurement, and the distinction matters here.**
Every KEEP the new rule admits is one the old rule also admitted — the new
thresholds are strictly tighter on both criteria — so the true rate at the new
defaults *cannot be higher* than the rate above. But "cannot be higher than a
figure whose own 95% upper bound is 3.62%" is a much weaker statement than a
measured rate, and it is the only one this README is entitled to make. **The
0/100 and 1/100 remain the only measured false-KEEP figures here, and they
describe the old rule.**

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

`doctor` covers **the canonical spelling of half of it**: it warns when
optimizable code declares `==`, `!=`, `<`, `<=`, `>`, `>=` or `~=` whose operands
are **entirely standard-library types**, on one line, written out. Those types
are already `Equatable`/`Comparable`, so such a declaration is not a conformance
— it is a shadowing redeclaration, and there is no ordinary reason to write one.
A hand-written `Equatable` conformance on your *own* types is ordinary and is
reported as a count, never a warning: a check that fires on every healthy
repository is a check people stop reading.

**It is a text scan, and an author who is trying can evade it.** Two evasions are
known, both of which compile and both of which land silently in the "ordinary"
tier:

```swift
public func !=
    (lhs: [String: Int], rhs: [String: Int]) -> Bool { false }   // params on the next line

public typealias Counts = [String: Int]
public func ~= (lhs: Counts, rhs: Counts) -> Bool { true }       // operand behind a typealias
```

The first is deliberate: when the operand list cannot be read, the check reports
the operator but refuses to guess that it is shadowing, because guessing would
mean warning on healthy code. The second needs type resolution — a compiler, not
a scan. Neither is fixed, because `doctor` is advisory and always exits 0, so the
cost of the gap is a missing hint while the cost of chasing it with more regex is
a check that warns on healthy code and is then ignored on the day it matters.
Both are recorded in the test suite so the limit stays visible, and `doctor`'s
own output says so in every branch — including the all-clear one. **Read a clean
result as "the obvious form is absent", not as "this cannot have been done."**

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
product is **not frozen**. Earlier versions of this README said `scope` closed
the resulting hole. **That was false, and it was demonstrated false.**

Gate 1 compares the paths *git reports* as changed between `frozenCommit` and
`HEAD`. `git update-index --assume-unchanged <helper>` makes git stop reporting
that file, so an edit to an out-of-scope helper was invisible to gate 1 — and to
gate 2b, which was reading `git status --porcelain`. The file stayed on disk and
was still compiled into the benchmark. Measured on the real binary: editing an
out-of-scope helper's `benchmarkRepeatCount` from 1750 to 1 behind git's back,
then committing **one comment line** to an in-scope file, returned `keep` with
**rc 0 and ratio 0.000737**.

**What closes it is gate 2c, not `scope`:** an on-disk inventory of every file
outside `scope`, hashed when `baseline` runs and re-walked on every eval. Any
out-of-scope file that is added, modified or removed is refused as `out_of_scope`
regardless of what git says about it. The same attack now returns rc 2, `fail`,
`k: 0`, naming the helper and both hashes.

So the honest statement is: **`scope` declares what the agent may change; it is
no longer trusted to detect what did change.** Out-of-scope helpers are still not
*frozen* — nothing restores them, and a legitimate edit to one requires a new
baseline — but they can no longer be edited without the harness noticing. If you
want a helper genuinely frozen and restored, fold it into the benchmark target
so it carries the `Benchmark` product dependency.

### 4. Manifest protection: what is and is not covered

Gate 2a hashes a manifest inventory recorded at baseline, which closes the
`git update-index --assume-unchanged` / `--skip-worktree` bypass for root and
nested manifests alike, including a manifest that *appears* where baseline
recorded none. Not covered:

- **Symlinked manifests are not followed.** The scan records the symlink's own
  bytes, so re-pointing the link is caught, but swapping the *target's* content is
  not. Untested and unfixed.
- **`.build` is not hashed by this gate.** A manifest planted there is not
  examined *as a manifest*. `.build/checkouts` is covered by gate 2d, against the
  revisions `Package.resolved` pins; `.build`'s build **output** is not covered
  by anything, and that is [its own residual](#the-build-cache-is-not-verified).
- The inventory is recorded at `frozenCommit` and **never refreshed on KEEP**.
  That is deliberate: it must not advance. It also means a *legitimate* manifest
  change requires a new baseline.

One case that *was* open here is now covered from the other direction. Gate 2a's
"is this a manifest" test is deliberately case-**sensitive**, which is right for
paths git reports — but APFS is case-insensitive, so SwiftPM honours
`PACKAGE@SWIFT-6.4.SWIFT` as a real version-specific manifest while that test
does not match the spelling. Gate 2c does not care what a file is called: it is
outside `scope`, so it appears as an extra file and is refused on that basis.
Two gates asking different questions is what catches it; neither would alone.

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

**macOS** is the developed and measured platform: `swift test` is **330 of 330**,
and every timing in this README was taken there.

**But it is not reliably green, and an earlier revision of this section implied
it was.** Writing this round, one full run came back `rc=1` with two failures —
`measurementCommitAdvancesAfterAKeep` and
`aWorktreeGitCanSeeIsDirtyIsRepairedRatherThanBrickingTheRun` — and both passed
in isolation, with the next full run returning `rc=0, 330 of 330`. That is the
**same test-isolation fragility described under Linux below**: several tests call
`BaselineRunner.run` concurrently against a SwiftPM cache shared under `HOME`.
**It is not a Linux-specific problem**, and this README said so only because it
had only been *observed* there. Both runs are recorded in the project's run log
rather than the green one being kept; if you get a red suite, re-run the failures
in isolation before assuming you broke something.

**The Linux suite has never been green, and this README is not going to round
that to "Linux works".** The honest statement is three separate claims:

1. **Linux builds and runs.** `swift:6.1`, `linux/arm64` (aarch64), Swift 6.1.3,
   kernel 6.12.76-linuxkit, glibc 2.39. `swift build -c release` is rc=0.
2. **The harness's own platform behaviour is verified there**, and that is the
   part that most needed it — process groups, session isolation and the sweep,
   subprocess handling, the signal trap, the state home, and the sampler.
3. **The full suite returns `rc=1`.** At the last Linux verification: **328
   tests, 8 issues.** (The macOS suite has moved on since — later rounds changed
   only `-c` arguments, call ordering and a content hash, none of it
   platform-specific, so Linux was not re-run. That is itself a gap: the figure
   below is the last one *measured*, not a figure for today's tree.) An operator
   who runs it will see a red result, and they have to separate **two different
   causes** to make sense of it:

| Cause | Count | What it is |
|---|---|---|
| `IntegrationTests` lockfile refusals | **7** | All the same message — `refusing to configure this repository: swift package resolve rewrote the tracked Package.resolved`. This is the cross-platform lockfile problem documented below, not a defect in the code under test: an earlier tree fails the identical seven with the identical message. |
| `anAssumeUnchangedOutOfScopeEditIsRefusedAndNeverMeasured` | **1** | **A genuine flake.** It passes 3/3 when run in isolation in the same container. Several tests call `BaselineRunner.run` concurrently against a SwiftPM cache shared under `HOME`, and the container makes that collision likelier — **but it is not caused by the container**: the same class has since been observed on macOS, as noted above. Pre-existing test-isolation fragility, amplified here — a real flake, recorded as one rather than re-run until green. |

So: **do not read `rc=1` on Linux as "the port is broken", and do not read it as
"expected, ignore it" either.** Seven of those eight are a fixture problem with a
known cause and a known workaround; the eighth is a flake in our own test
isolation. Anything beyond those eight is new and worth reporting.

> **HOW MUCH THE LINUX CLAIM IS WORTH — a method caveat, and it is uncomfortable.**
> Two tests passed on macOS while **asserting nothing at all on Linux**, and had
> done so since the day they were written. `exec -a` is a bashism that `dash`
> does not support, so the process tagging they relied on silently did nothing in
> the container. Worse, `pgrep -f` matches the *whole command line* of every
> process — including the command line of the shell running `pgrep` — so with the
> marker spelled inline the matcher **matched its own wrapper** and reported a
> survivor that was nothing but the question being asked. Both were found only by
> actually running them on Linux, not by reading them.
>
> The correct inference is not "those two are fixed now". It is: **assume other
> macOS-only-verified tests may have the same problem.** Only five areas have
> actually been exercised on Linux — `ProcessGroupTests`, `SubprocessTests`,
> `SignalTrapTests`, `StateHomeTests`, `SamplerTests`. A green macOS suite is
> evidence about macOS.

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

The test suite is **330 tests on macOS**, all passing, and takes several minutes:
a good part of it builds and measures the real fixture package with the real
benchmark harness, because the things worth testing here are the ones that only
fail for real. On Linux it is **328 tests with 8 issues** — see
[limitation 11](#11-platform-and-environment) for what those eight are and why
neither "it's broken" nor "ignore it" is the right reading.

## Licence

MIT. See [LICENSE](LICENSE).

Gal Be &lt;galevgi@gmail.com&gt;
