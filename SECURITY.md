# Security model

This is the long form. [The README](README.md#security) carries the summary; this
file carries the evidence, unabridged, because a claim about what a harness
resists is worth exactly as much as the measurement behind it.

**Nineteen bypasses have been found across nine reviews. Seventeen are closed.
Two are open and named.** Every attack below was run against a real release
binary, before and after, and every figure traces to an entry in this project's
run log. Where a fix is closed *by construction* rather than *by demonstration*,
that is said.

> **The one-sentence version, if you read nothing else.** `eval` compiles and
> executes code the agent wrote, as the same user, with no sandbox, on a
> filesystem containing the pinned baseline worktree and the harness's own state.
> **`autor3search-swift` does not prevent that; it detects the part that would
> change a verdict.**

---

## The root cause, in one sentence

Nine reviews produced nineteen bypasses. Most of the later ones are the same
defect wearing different faces, and it is worth stating before any of the
individual stories:

> **A check performed before gate 6 vouches for state consumed after gate 6.**
> Gate 6 runs `swift test`, which is the agent's code by construction.

Every read-only gate — scope, config, manifests, the dirty tree, the
out-of-scope inventory, the dependency checkouts — runs before gate 6. Several of
the things they vouch for are then *used* after it: the baseline side is built at
gate 7 from checkouts verified at gate 2d, `measurementCommit` is set from a HEAD
read after measuring, the worktree's build-tool plugins are executed by the gate-7
build. Between the check and the use sits an execution of arbitrary agent code.

**And the window is wider than gate 6.** Instrumenting one reproduction showed
the payload firing from two `argv[0]`s — `swiftpm-testing-helper` (gate 6) **and
`Bench` (gate 8, the measurement itself)**. The gate-8 firing is what made a
poisoned baseline *self-renewing*: once the pinned worktree held the payload
commit, the **baseline binary** re-committed the poisoned benchmark on every
later experiment. That is why the HEAD check runs twice — at **6b** and again at
**8b**.

### Why not just move gate 6?

The obvious fix is to reorder, and it does not work — for structural reasons, not
incidental ones:

- **`swift test` must run *after* gate 3's frozen restore.** Before it, the tests
  on disk are the candidate's own, and a candidate that weakens its own tests
  passes a test gate that means nothing. That is the entire purpose of freezing
  them.
- **Every read-only integrity gate must run *before* gate 3**, because gate 3 is
  the first thing in the chain that *writes* to the repository. Checking after it
  would be checking the harness's own restore.

So gate 6 is pinned between the checks and the state they vouch for. Moving it
*later* does not help either: it would still precede the advance, so HEAD adoption
survives, and the baseline binary would by then have been built from whatever the
tests left behind. **The window can only be closed by re-checking** — which is
gate **6b**, running immediately after the test phase and re-running HEAD
equality, `.build/checkouts` on both sides, root-manifest hashes, the manifest
inventory, the dirty tree, the out-of-scope inventory, and tracked content
against HEAD's blobs, then re-purging the plugin cache on both sides.

### What is re-checked, what is not, and why

A published list of what is *not* covered is worth more than a claim that
everything is. Every pre-gate-6 check, its subject, and whether that subject can
still move:

| Check | Subject | Mutable after gate 6? | Consumed after gate 6? | Covered by |
|---|---|---|---|---|
| run claim (flock) | the lock file | yes, but harness-owned and single-writer | no | n/a |
| **1** scope, `frozen..HEAD` | HEAD's commit set | **yes** — `swift test` *and* the gate-8 binaries can commit | yes, by the advance | gate 6b + gate 8b + `headUnderTest` |
| **2** config hash | `config.yaml` bytes | yes | no — values are held in memory | *incidental* (tracked content at 6b) |
| **2a** root manifests | `Package.swift`, `Package.resolved`, `.swiftpm` | yes | **yes** — the gate-7 build resolves them | re-checked at 6b |
| **2a** manifest inventory | every manifest in the tree | yes | yes, same | re-checked at 6b |
| **2b** dirty tree + ignored record | working tree, ignored files | yes | **yes** — the next eval starts here | re-checked at 6b |
| **2c** out-of-scope inventory | files outside `scope` | yes | repo copy already compiled at gate 5 | re-checked at 6b |
| **2e** tracked content vs blobs | repo tracked files | yes | as above | re-checked at 6b |
| **2d** `.build/checkouts`, both sides | dependency sources | **yes** | **yes — the worktree's copy is compiled at gate 7** | re-checked at 6b |
| **3** frozen restore | frozen files in the repo | yes | already compiled and run by gates 5 and 6 | *repo copy: by 2c/2e at 6b* |
| **4** new files | files the candidate added | yes | as above | as above |
| **4b** plugin purge, both sides | `.build/plugins` | **yes** | **yes — executed by the gate-7 build** | re-purged at 6b |
| **5** build + binary snapshot | the four measured binaries | yes | yes | snapshot moved per side + per-sample guard |

**Two rows are deliberately left alone, and the reasons matter more than the
rows.**

- **The config hash.** The config is parsed once and the *parsed values* are used.
  Re-reading it after gate 6 would mean **re-deciding the rules mid-experiment**,
  which is worse than the thing it would catch. Its bytes are still tracked
  content, so a mid-eval edit is caught by the tracked-content re-check anyway.
- **The frozen restore and the new-file scan.** The repository's copy has already
  been compiled by gate 5 and run by gate 6 by the time 6b could look, so
  re-checking would report a fact about a build that has finished. The
  *worktree's* copy is handled by `restoreToPin`, which already runs after gate 6.

## Two checks that do not depend on any list being complete

Read this before the enumeration below, because it is the reason the tool is
shippable despite that enumeration being incomplete and *known* to be
incomplete.

Most of the hardening in this document is a list: of exempt regions, of config keys
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

**File mode is not a defence**, and it is worth one line because it looks like
one. The attack on the worktree's dependency checkouts did not reproduce at
first: SwiftPM leaves checkout *files* at `0444`, so a plain write fails with
`EACCES`. But their *directories* stay `0755` — so one `chmod`, or simply an
atomic write that renames over the read-only file from the writable directory,
defeats it entirely. Nothing in this harness claims read-only permissions as a
control, and nothing should.

**And when you get a principle right, check whether you applied it everywhere.**
The snapshot-placement rule above was established for the baseline side and then
left unapplied to the candidate side, which had the larger hole — the same shape
of attack, the same fix, missed because the work stopped when the first side was
done. In the implementer's words:

> *Round 9 established the principle and I applied it to one side. Assume the
> same question is worth asking of anything else that has two sides.*

That generalises further than binaries. Anything with a symmetry — two sides, two
platforms, two directions, a before and an after — is somewhere a correct
principle can be half-applied and look finished.

## Every exemption from an integrity check is a candidate bypass

This is the most transferable thing in the project, and it is worth more than
any individual gate above.

**Nineteen bypasses have been found across nine reviews — seventeen closed, two
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

## The environment is filtered, by allowlist

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
**defence in depth, not a measured closure**, and this document will not call it
one.

## Git config that runs programs: what is denied, and what cannot be

`core.hooksPath` was never the only key that makes git execute something. Every
git call the harness makes now denies **twenty-one** keys, taken from `git config`'s
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

## What did *not* work, which is also a result

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
drift across a run (see [Why a rank test](README.md#why-a-rank-test)); it does not cancel
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

**And then the same attack came back on the other side.** The fix above protected
the *baseline* binary by snapshotting after the build that produces it. The
*candidate* binary is built at gate 5 — and **gate 6 then runs `swift test`,
which is the agent's code by construction** — while the snapshot was still not
taken until after the baseline build, later still. So a binary swapped in during
the test phase was **adopted by the guard as its own reference** rather than
detected. An in-scope commit whose `countWords` was the **byte-identical**
quadratic original, plus a lazy global firing only inside the test runner,
returned `keep` with `rc 0` at ratios 0.11710 / 0.12203 / 0.12292 and
`warnings: []`, with a byte-clean tree and every gate passing. **Each side is
now snapshotted immediately after its own build** — candidate at gate 5, before
the tests; baseline at gate 7 — so neither reference can be taken after a swap.

> **RESIDUAL: the test phase is bounded for binaries, and not otherwise
> bounded.** `swift test` runs the agent's code, by construction — that is what
> gate 6 *is*. Nothing stops it doing something other than swapping a binary.
> Writing the baseline worktree is caught (the guard); spawning survivors is
> caught (the session sweep); something not yet enumerated is not caught, because
> it is not yet enumerated. The two binaries on each side are covered. The
> execution surface they sit on is not.

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

**That sentence was false for a while, and it is worth knowing how.** It was
asserted rather than enforced: `measurementCommit` was set from a fresh
`git.head()` read *after* measuring, so a commit created during the test phase —
inspected by no gate — was adopted as the new baseline. It is now **enforced**:
the commit gate 1 judged is captured once and carried through, the advance
credits *that* commit, and `HEAD` is re-compared at gates 6b and 8b. If it has
moved, the eval refuses with `head_moved_during_eval` before anything is built or
sampled. The property holds because a check makes it hold, not because the code
had no other way to behave.

### The build cache is not verified

**The build cache is not verified.** An agent that can write into `.build/` can
put code into the measured binary that no gate hashed: llbuild decides what to
rebuild from recorded input signatures, so a poisoned object file or linked
binary under `.build/out`, belonging to a module whose sources did not change, is
reused rather than recompiled. `autor3search-swift` deletes the compiled
build-tool plugins (`.build/plugins`) before every build, because those are
executed rather than merely linked and the deletion costs about 0.8 s per side;
it does not delete the rest, which measured ~18 s per side and would roughly
double the cost of every experiment.

> **`purge_build_output` IS NOT A GENERAL REMEDY, and an earlier revision of this
> section said it was.** It purges at gate 4b, **before** the build — so it
> discards a **stale** poisoned artifact left by a previous eval, and has nothing
> whatever to say about one written **during** this one. That was measured, not
> reasoned: with `AUTOR3SEARCH_SWIFT_PURGE_BUILD_OUTPUT=1` set, an attack that
> swapped the candidate binary mid-eval still returned **`rc 0`, `keep`, ratio
> 0.11489**, and the binary's SHA-256 after the eval was byte-identical to the
> staged poisoned one. The flag did exactly what it says and it was not enough.
>
> **What covers a binary written mid-eval is the per-side snapshot**, not the
> purge: each side's binaries are hashed immediately after **its own** build —
> the candidate at gate 5, *before* `swift test` runs the agent's code, and the
> baseline at gate 7 — and re-checked before every sample. Neither side's
> reference can be taken after a swap. See
> [boundary 1](#boundary-1--the-agents-benchmark-runs-unsandboxed).
>
> So: set `purge_build_output` if you want each eval to start from artifacts
> rebuilt out of verified sources, at the cost below. Do not set it expecting it
> to stop a benchmark or a test from writing a binary while the eval is running;
> that is a different problem with a different answer.

The real remedy for the residual is operational: run the harness where the agent
cannot write `.build`.

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

### An agent can stop your overnight run in one line

A residual created by the fixes above, and a deliberate trade rather than an
oversight. Once a poisoned dependency checkout is detected, **every later eval
refuses with `dependency_checkout_modified` until a human deletes the affected
checkout** and lets SwiftPM re-clone it from the pin. That is correct and safe —
the alternative is measuring against a checkout nobody vouches for — but it means
an agent that writes one byte into `.build/checkouts` can **halt an unattended run
until a person intervenes.** Detection converts a silent false KEEP into a loud
stop, and a loud stop is still a stop.

**This is inconsistent with the precedent set elsewhere in the harness**, and the
inconsistency is worth naming rather than defending. For harness-owned state the
rule is *repair, don't refuse*: gate 7 restores the pinned worktree rather than
refusing it, precisely so one `touch` cannot end a night's work. The consistent
fix here is the same — delete the worktree's checkout and let SwiftPM re-clone it
from the revision `Package.resolved` pins, since the correct contents are known
exactly. **It is not implemented.** Note the asymmetry it would need: the
*candidate* side must still refuse, because a candidate whose dependency sources
were tampered with is a candidate under test, not harness state to be repaired.

**Two narrower residuals from the same area**, stated because they are the edges
of what was actually tested:

- **The `.build/checkouts` re-check covers files SwiftPM has already checked
  out.** A mid-eval *deletion* followed by a re-clone from a tampered
  `repositories/` cache is **untested**. The lockfile hash makes it narrow; narrow
  is not closed.
- **Gate 6b costs two extra inventory passes per eval, and that cost was not
  measured.** Every other cost in this README is a number taken from a run; this
  one is not, and is not being presented as free. On a large repository, budget
  for it until someone measures it.

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

