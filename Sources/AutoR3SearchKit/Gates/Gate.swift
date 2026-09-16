import Foundation

/// A gate refused to let a run proceed. Gates run before anything is built
/// or measured — a `GateFailure` here is the harness saying "no" before it
/// has spent any wall-clock time, not a measurement result.
public struct GateFailure: Error, CustomStringConvertible, Equatable {
    /// Machine-readable. Goes in `--json` verbatim, so it is a stable
    /// contract: existing reasons never change spelling once shipped.
    public let reason: String

    /// Human-readable. Printed above the verdict. For a refusal an agent (or
    /// its operator) needs to act on, this should teach the "why", not just
    /// state the "what" — see `ScopeGate`'s manifest rejection for the
    /// motivating case.
    public let detail: String

    public init(reason: String, detail: String) {
        self.reason = reason
        self.detail = detail
    }

    public var description: String { "\(reason): \(detail)" }
}
