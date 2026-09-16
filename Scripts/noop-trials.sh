#!/bin/sh
# Scripts/noop-trials.sh -- run N genuine no-op experiments and count spurious KEEPs.
#
# A no-op commit changes only a comment. The compiled code is byte-for-byte the
# work of the same source, so ANY KEEP is a false positive BY CONSTRUCTION: no
# estimate is involved, and no judgement call about whether the change "really"
# helped. That is the whole reason this measurement is worth anything.
#
# WHAT THE NUMBER DEPENDS ON, and it is not the number of trials.
# The false-KEEP rate is a property of the harness AND of the scale of the
# benchmark it is pointed at. Task 21 measured that at ~48 us per iteration two
# builds of IDENTICAL code drift by about +/-3% systematically -- not noise
# around 1.0 -- because the baseline side and the candidate side are different
# binaries in different directories and are therefore not exchangeable samples.
# At ~424 us the same comparison came back ratio 1.0018, p 0.218. Run this
# script at both scales or state which one you ran it at; a rate measured where
# the harness is drift-dominated is a measurement of the fixture, not of the
# harness.
#
# DO NOT "FIX" A BAD RESULT BY RAISING config.count. More rounds per side make
# Mann-Whitney BETTER at resolving a biased estimate, so a higher count makes a
# drifting no-op MORE likely to read significant, not less.
#
# Usage:
#   sh Scripts/noop-trials.sh <repo> [N] [outdir]
#
#   <repo>    a package already through `init` + `baseline` (so HEAD is on the
#             run branch autor3search-swift/<tag>), with a benchmark, a test
#             suite, and a clean working tree.
#   N         number of trials, default 100.
#   outdir    where per-trial JSON and the TSV land, default /tmp.
#
# The binary is taken from $AUTOR3SEARCH_BIN if set, else from PATH.
# Set AUTOR3SEARCH_SWIFT_STATE_HOME (absolute) to keep a trial run's state
# isolated from any other run on this machine.
set -e

REPO="$1"; N="${2:-100}"; OUT="${3:-/tmp}"
BIN="${AUTOR3SEARCH_BIN:-autor3search-swift}"

if [ -z "$REPO" ]; then
    echo "usage: sh Scripts/noop-trials.sh <repo> [N] [outdir]" >&2
    exit 64
fi
mkdir -p "$OUT"
TSV="$OUT/noop-trials.tsv"
printf 'trial\trc\tverdict\treason\tratio\tp\tbaseline_ns\tcandidate_ns\tseconds\n' > "$TSV"

keep=0; discard=0; other=0
started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "noop-trials: repo=$REPO N=$N started=$started"

for i in $(seq 1 "$N"); do
    printf '\n// no-op trial %s\n' "$i" >> "$REPO/Sources/Demo/Demo.swift"
    # Staged BY PATH, not `git add -A`: a stray untracked file in the tree
    # would otherwise ride along in the commit and turn a no-op into a scope
    # rejection (a FAIL), silently changing what this script measures.
    git -C "$REPO" add -- Sources/Demo/Demo.swift
    git -C "$REPO" commit -q -m "no-op trial $i"

    t0=$(date +%s)
    # THE rc CAPTURE. `$BIN eval ... | something` would report the pipe's exit
    # status, not eval's, and every trial would silently read as a KEEP.
    set +e
    "$BIN" eval -C "$REPO" --json > "$OUT/noop-$i.json" 2>"$OUT/noop-$i.err"
    rc=$?
    set -e
    t1=$(date +%s)

    row=$(python3 - "$OUT/noop-$i.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("?\t?\t\t\t\t"); raise SystemExit
b = (d.get("benchmarks") or [{}])[0]
def f(x): return "" if x is None else repr(x)
print("\t".join([
    str(d.get("verdict", "?")), str(d.get("reason") or ""),
    f(b.get("ratio")), f(b.get("pValue")),
    f(b.get("baselineMedian")), f(b.get("candidateMedian")),
]))
PY
)
    printf '%s\t%s\t%s\t%s\n' "$i" "$rc" "$row" "$((t1 - t0))" >> "$TSV"

    case "$rc" in
        0) keep=$((keep+1)); echo "trial $i: SPURIOUS KEEP  [$row]" ;;
        1) discard=$((discard+1)); echo "trial $i: discard  [$row]" ;;
        # FAIL (2) and CRASH (3) are neither a KEEP nor a DISCARD. Folding them
        # into "discard" would understate the error rate by counting a run that
        # produced no verdict as a correct rejection.
        *) other=$((other+1)); echo "trial $i: OTHER rc=$rc  [$row]" ;;
    esac

    git -C "$REPO" reset --hard -q HEAD~1
done

echo "trials=$N keep=$keep discard=$discard other=$other"
echo "false-KEEP rate: $(python3 -c "print(f'{100*$keep/$N:.1f}%')")"

# The observed count is the result; the interval is how far the count can be
# trusted. With 0 events in N trials the rate is NOT zero -- the exact upper
# bound is about 3/N (the rule of three), and it is printed here so nobody has
# to take "we never saw one" as "it cannot happen".
python3 - "$keep" "$N" <<'PY'
import math, sys
k, n = int(sys.argv[1]), int(sys.argv[2])
def tail_ge(p, k, n): return sum(math.comb(n, i) * p**i * (1-p)**(n-i) for i in range(k, n+1))
def tail_le(p, k, n): return sum(math.comb(n, i) * p**i * (1-p)**(n-i) for i in range(0, k+1))
def bisect(f, target):
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if f(mid) < target: lo = mid
        else: hi = mid
    return (lo + hi) / 2
lo = 0.0 if k == 0 else bisect(lambda p: tail_ge(p, k, n), 0.025)
hi = 1.0 if k == n else bisect(lambda p: -tail_le(p, k, n), -0.025)
print(f"observed {k}/{n}; 95% Clopper-Pearson exact CI [{100*lo:.2f}%, {100*hi:.2f}%]")
if k == 0:
    print(f"zero observed does not mean zero: rule of three gives ~{300.0/n:.2f}% as the 95% upper bound")
PY
echo "per-trial rows: $TSV"
