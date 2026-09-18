// Sources/AutoR3SearchKit/State/StopRequest.swift
//
// `stop` is how a human ends an unattended overnight run gracefully. Writing
// this marker does not interrupt anything by itself: `eval` only ever READS
// it (folded into every verdict as `stopRequested` -- see
// `EvalRunner.run`), so the experiment already in flight when the request
// lands still finishes and is scored, its KEEP or DISCARD is applied to the
// baseline and the pinned worktree exactly as it would have been anyway, and
// only THEN does the agent's own loop see `stopRequested: true` in that
// verdict and choose to stop launching further experiments. Nothing in
// flight is thrown away by a plain `stop`. (`--force`, which additionally
// abandons the in-flight experiment by signaling the process holding the
// run's claim, lives in `StopRunner` -- this type only ever manages the
// marker file itself.)
import Foundation

public enum StopRequest {
    /// Writes the request. Idempotent: requesting a second time just
    /// rewrites the same marker with the same content.
    public static func request(home: StateHome, tag: String) throws {
        let url = try home.stopRequestURL(tag: tag)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("requested".utf8).write(to: url, options: .atomic)
    }

    /// Cancels a pending request. Best-effort and idempotent: clearing a
    /// request that was never made, or was already cleared, is not an
    /// error -- a human re-running `stop --clear` "just to be sure" must
    /// never fail.
    public static func clear(home: StateHome, tag: String) throws {
        try? FileManager.default.removeItem(at: try home.stopRequestURL(tag: tag))
    }

    /// Whether a stop has been requested for this run. Read-only: checked by
    /// `eval` on every invocation and by `status` for a human to see.
    public static func isPending(home: StateHome, tag: String) -> Bool {
        guard let url = try? home.stopRequestURL(tag: tag) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
