#!/bin/sh
# Scripts/linux-verify.sh -- CORRECTNESS ONLY. No timings are taken here:
# benchmarking inside a container on a Mac produces numbers we would have to
# disown, and this project states plainly that no Linux timings exist. What is
# verified is that the platform abstraction actually works on Linux:
#
#   1. the package builds and the whole test suite passes on Linux/aarch64;
#   2. the process-tree kill and the SIGTERM/SIGINT trap -- the Linux branches
#      of ProcessTree/SignalTrap, which on macOS are never compiled -- behave
#      (SignalTrapTests and SubprocessTests spawn real children and real
#      grandchildren and assert the whole tree dies);
#   3. the `perf`-based profile path REFUSES LOUDLY, naming
#      /proc/sys/kernel/perf_event_paranoid, instead of silently producing an
#      empty or fabricated profile. A default container has paranoid=2 and no
#      `perf` binary, which is exactly the condition that refusal exists for,
#      so the container is the honest place to test it.
#
# The host's .build is NEVER used: the container builds into a scratch path
# inside a DOCKER NAMED VOLUME. Linux object files landing in the macOS .build
# would silently poison the next host build, and a host bind-mount for the
# scratch path would drop Linux build artefacts into the working tree. The
# named volume also means the stages below share one build instead of
# recompiling the package three times.
#
# Usage: sh Scripts/linux-verify.sh [stage]
#   stage: all (default) | test | areas | perf
# Env: IMAGE (default swift:6.1), SCRATCH (container-side scratch path),
#      VOLUME (docker named volume holding it)

IMAGE="${IMAGE:-swift:6.1}"
SCRATCH="${SCRATCH:-/linux-build}"
VOLUME="${VOLUME:-autor3search-linux-build}"
STAGE="${1:-all}"
SRC="$(pwd)"
MOUNTS="-v $SRC:/src -v $VOLUME:$SCRATCH"

echo "linux-verify: image=$IMAGE stage=$STAGE src=$SRC"
docker version --format 'docker server {{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}'

APT="apt-get update -qq && apt-get install -y -qq libjemalloc-dev >/dev/null 2>&1"

# Environment report plus per-area suites. Each area's rc is captured on the
# `swift test` invocation ITSELF -- `swift test | tail` would report tail's
# status and every area would read as passing.
run_areas() {
    docker run --rm $MOUNTS -w /src "$IMAGE" sh -c "
        uname -a; swift --version; git --version
        $APT
        if ls /usr/lib/*/libjemalloc* >/dev/null 2>&1; then
            echo 'jemalloc: present'
        else
            echo 'jemalloc: ABSENT -- allocation metrics degrade to unavailable, a documented difference, not a failure'
        fi
        for area in SignalTrapTests SubprocessTests SamplerTests StateHomeTests; do
            swift test --scratch-path $SCRATCH --filter \"\$area\" > /tmp/\$area.log 2>&1
            rc=\$?
            tail -2 /tmp/\$area.log
            echo \"AREA \$area rc=\$rc\"
        done
    "
}

# The full suite, run WITHOUT a pipe so the exit status belongs to `swift test`
# itself and propagates out of `docker run`.
run_full() {
    docker run --rm $MOUNTS -w /src "$IMAGE" sh -c "
        $APT
        swift test --scratch-path $SCRATCH > /tmp/full.log 2>&1
        rc=\$?
        tail -40 /tmp/full.log
        echo \"FULL swift test rc=\$rc\"
        exit \$rc
    "
}

# The perf refusal, exercised through the real CLI on the real fixture rather
# than asserted in a unit test: `profile` must name the reason and exit
# non-zero, never print an empty ranking as if it had sampled something.
run_perf() {
    docker run --rm $MOUNTS -w /src "$IMAGE" sh -c "
        $APT
        echo '--- perf environment in this container ---'
        echo \"perf_event_paranoid: \$(cat /proc/sys/kernel/perf_event_paranoid 2>&1)\"
        ls -l /usr/bin/perf /usr/lib/linux-tools/perf /usr/local/bin/perf 2>&1 | head -5

        swift build -c release --scratch-path $SCRATCH --product autor3search-swift || exit 90
        BIN=\"\$(swift build -c release --scratch-path $SCRATCH --show-bin-path)/autor3search-swift\"

        rm -rf /tmp/demo && mkdir -p /tmp/demo && cp -R Fixtures/DemoPackage/. /tmp/demo/
        cd /tmp/demo || exit 92
        git init -q -b main
        git config user.name 'Gal Be'
        git config user.email 'galevgi@gmail.com'

        # THE LOCKFILE IS NOT PORTABLE, and pretending otherwise would make
        # this stage fail for a reason that has nothing to do with perf.
        # ordo-one/benchmark's dependency graph is platform-conditional: on
        # macOS it resolves ordo-one/malloc-interposer, on Linux
        # ordo-one/package-jemalloc, at different versions. A Package.resolved
        # committed on macOS is therefore REWRITTEN by \`swift package resolve\`
        # on Linux, and \`init\` correctly refuses to commit someone else's
        # dependency change on their behalf. Re-resolve here and commit the
        # Linux lockfile before init runs.
        swift package resolve --scratch-path /tmp/demo-scratch >/dev/null 2>&1
        git add -A && git commit -q -m fixture
        export AUTOR3SEARCH_SWIFT_STATE_HOME=/tmp/state
        \"\$BIN\" init -C /tmp/demo || exit 91

        echo '--- profile, branch 1: no perf binary (expected LOUD refusal, rc != 0) ---'
        \"\$BIN\" profile -C /tmp/demo --seconds 2
        echo \"profile rc=\$?\"

        # BRANCH 2, and the honest caveat that goes with it. Debian/Ubuntu
        # aarch64 in this image has no installable \`perf\` matching the
        # linuxkit kernel, so the paranoid>1 refusal cannot be reached with a
        # REAL perf. \`Sampler.linuxPerfPath()\` only tests the candidate paths
        # for executability, so a stub at /usr/local/bin/perf reaches the same
        # branch and proves the refusal fires on perf_event_paranoid rather
        # than only on a missing binary. What this does NOT verify is real
        # perf attachment, record or script parsing -- that needs a host where
        # perf works, and this run makes no claim about it.
        echo '--- profile, branch 2: perf present but perf_event_paranoid too strict ---'
        printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/perf && chmod +x /usr/local/bin/perf
        \"\$BIN\" profile -C /tmp/demo --seconds 2 2>&1 | head -20
        rm -f /usr/local/bin/perf
    "
}

case "$STAGE" in
    areas) run_areas ;;
    test)  run_full ;;
    perf)  run_perf ;;
    all)
        run_areas; areas_rc=$?
        run_full;  full_rc=$?
        run_perf;  perf_rc=$?
        echo "linux-verify: areas stage rc=$areas_rc, full swift test rc=$full_rc, perf stage rc=$perf_rc"
        ;;
    *) echo "unknown stage: $STAGE" >&2; exit 64 ;;
esac
