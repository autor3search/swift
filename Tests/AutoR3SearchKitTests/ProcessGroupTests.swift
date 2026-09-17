import Testing
import Foundation
@testable import AutoR3SearchKit

// Tests/AutoR3SearchKitTests/ProcessGroupTests.swift
//
// THE TWELFTH VECTOR, and the honest limit of the fix for it.
//
// Round 6 guards the BYTES being measured. This one changes no bytes: a
// candidate benchmark whose `countWords` is the original quadratic
// implementation spawns background CPU burners that OUTLIVE it, idling while
// the candidate runs and saturating the machine during the BASELINE samples
// that follow. `MeasureSession` interleaves B,C,B,C, so every baseline sample
// after the first runs on a loaded machine. The asymmetry is the trick: the
// process running the agent's code can leave something behind that penalises
// the side it is compared against.
//
// Measured against the real binary, in-group burners spawned with
// `posix_spawn`:
//
//   before: rc 0  keep  k 1  ratio 0.51843  baseline 7.45 ms  candidate 3.86 ms
//                                           12 burners still alive afterwards
//   after:  rc 1  discard k 1 ratio 1.01978  baseline 4.09 ms
//                                           0 burners still alive
//
// The fix is that every `Subprocess.run` now ends with a process-group kill,
// not only the timeout path. That is a correctness fix before it is a security
// one: each sample is supposed to be an independent observation, and a process
// surviving between samples breaks that whether it is malicious or a leaked
// helper.

private func pidsMatching(_ needle: String) -> [String] {
    guard let r = try? Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "pgrep -f '\(needle)' || true"],
        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), env: nil, timeout: 30)
    else { return [] }
    return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

private func reap(_ needle: String) {
    _ = try? Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "pkill -f '\(needle)' || true"],
        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), env: nil, timeout: 30)
}

/// A grandchild left running in the child's own process group does NOT survive
/// the run. This is the leak the interleaved measurement cannot tolerate.
@Test func aLeakedGrandchildInTheGroupDoesNotSurviveTheRun() throws {
    let marker = "autor3search-group-test-\(UUID().uuidString)"
    defer { reap(marker) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    // `sleep` backgrounded by a non-interactive shell stays in the shell's
    // group, and the shell is the group leader the harness spawned.
    let r = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "/bin/sh -c 'exec -a \(marker) /bin/sleep 45' & echo spawned"],
        cwd: tmp, env: nil, timeout: 30)
    #expect(r.exitCode == 0, "\(r.stderr)")
    #expect(r.stdout.contains("spawned"), "the run itself must still work normally")

    // The kill happens before `run` returns, so there is nothing to wait for.
    #expect(pidsMatching(marker).isEmpty,
            "a grandchild in the group survived the run: \(pidsMatching(marker))")
}

/// THE MEASURED LIMIT, pinned so it is documented in code rather than folklore.
///
/// A child that puts itself in a NEW process group escapes a group kill. This
/// is not an exotic manoeuvre: Foundation's own `Process` does it by default --
/// measured directly, a `Process`-spawned child reports `pgid == its own pid`
/// while a `posix_spawn`ed one inherits the parent's group. So the easiest way
/// an agent would write this attack is the way that escapes.
///
/// Closing it needs the sample to run in its own SESSION and the session to be
/// enumerated and killed (`setpgid` cannot leave a session; only `setsid` can),
/// which is a change to the spawn attributes in `ProcessTree`. Recorded as a
/// residual rather than claimed.
@Test func aGrandchildThatLeavesTheGroupSurvivesAndThatIsTheKnownLimit() throws {
    let marker = "autor3search-escape-test-\(UUID().uuidString)"
    defer { reap(marker) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    // The parent stays alive for a moment, which is what a real benchmark does:
    // it spawns the helper and then runs for a second or more. Without that the
    // kill lands before the helper has finished calling `setpgrp` and the
    // escape loses a race it would not lose in practice -- itself worth
    // knowing, and the reason this sleep is here rather than being tidied away.
    let escape = """
        /usr/bin/python3 -c "import os,time; os.setpgrp(); time.sleep(45)" \(marker) & \
        /bin/sleep 1; echo spawned
        """
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", escape],
                               cwd: tmp, env: nil, timeout: 30)
    #expect(r.exitCode == 0, "\(r.stderr)")

    // Give it a moment to call setpgrp and settle.
    Thread.sleep(forTimeInterval: 0.3)
    #expect(!pidsMatching(marker).isEmpty, """
        the premise of the recorded residual no longer holds: a process that left the group was \
        killed anyway. If this starts failing, the limit documented in the run log has been \
        closed by something and the note should be revisited.
        """)
}

/// The kill must not disturb the ordinary path: exit status, stdout and stderr
/// all still arrive intact, and a non-zero exit is still reported as data.
@Test func theGroupKillDoesNotDisturbOrdinaryRuns() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let ok = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
                                ["-c", "printf out; printf err >&2; exit 0"],
                                cwd: tmp, env: nil, timeout: 30)
    #expect(ok.exitCode == 0)
    #expect(ok.stdout == "out")
    #expect(ok.stderr == "err")

    let bad = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 7"],
                                 cwd: tmp, env: nil, timeout: 30)
    #expect(bad.exitCode == 7, "a non-zero exit is data and must survive the kill")
    #expect(!bad.timedOut)

    // A large output still round-trips: the kill happens after the child is
    // reaped but before the drains are stopped, so it must not truncate.
    let big = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "i=0; while [ $i -lt 2000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done"],
        cwd: tmp, env: nil, timeout: 60)
    #expect(big.exitCode == 0)
    #expect(big.stdout.split(separator: "\n").count == 2000,
            "output was truncated by the teardown: got \(big.stdout.count) bytes")
}

/// ...and a timeout still reports `timedOut`, with the tree killed, exactly as
/// before. The new unconditional kill sits alongside that path, not instead of
/// it.
@Test func aTimeoutStillReportsTimedOutAndStillKillsTheTree() throws {
    let marker = "autor3search-timeout-test-\(UUID().uuidString)"
    defer { reap(marker) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let r = try Subprocess.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "/bin/sh -c 'exec -a \(marker) /bin/sleep 45' & /bin/sleep 45"],
        cwd: tmp, env: nil, timeout: 1)
    #expect(r.timedOut)
    #expect(pidsMatching(marker).isEmpty, "the timeout path must still reach grandchildren")
}
