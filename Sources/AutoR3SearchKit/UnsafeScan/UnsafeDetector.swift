// Sources/AutoR3SearchKit/UnsafeScan/UnsafeDetector.swift
//
// Reports newly-introduced unsafe constructs; never rejects them. In Swift,
// `withUnsafeMutableBufferPointer` and friends ARE the idiomatic way to write the
// optimizations this tool exists to find, so a gate that rejected them would reject
// a large fraction of genuine wins. Frozen tests verify behaviour but cannot catch
// undefined behaviour, so the human reviewing an overnight branch needs to know
// exactly which commits introduced unsafe constructs before merging.
//
// This makes the detector's error costs asymmetric: a false positive costs an
// unnecessary read; a false negative costs a missed UB review. Detection here is
// deliberately biased toward over-reporting when a case is lexically ambiguous.
import Foundation

public struct UnsafeHit: Equatable, Sendable, Codable {
    public let file: String
    public let line: Int
    public let construct: String
    public init(file: String, line: Int, construct: String) {
        self.file = file; self.line = line; self.construct = construct
    }
}

public enum UnsafeDetector {
    /// Order matters: longer constructs first so `UnsafeMutablePointer` is not
    /// reported merely as `UnsafePointer`.
    static let constructs = [
        "withUnsafeMutableBufferPointer", "withUnsafeBufferPointer",
        "withUnsafeMutableBytes", "withUnsafeBytes",
        "UnsafeMutableRawBufferPointer", "UnsafeMutableBufferPointer",
        "UnsafeRawBufferPointer", "UnsafeBufferPointer",
        "UnsafeMutableRawPointer", "UnsafeMutablePointer",
        "UnsafeRawPointer", "UnsafePointer",
        "assumingMemoryBound", "unsafeBitCast", "unsafeDowncast",
        "@unchecked Sendable", "nonisolated(unsafe)", "unsafeAddress",
    ]

    /// A location inside a Swift string literal that is currently open.
    private enum Frame {
        /// Inside the literal content of a string. `hash` is the number of `#`
        /// delimiters (0 for an ordinary string), `multiline` marks a `"""` string.
        case str(hash: Int, multiline: Bool)
        /// Inside a `\(...)` (or `\#(...)`) interpolation, which is real code, not
        /// string content. `depth` counts unmatched `(` seen since the interpolation
        /// opened, so the matching `)` can be found even with nested parens.
        case interp(depth: Int)
    }

    /// Replaces comment and string-literal *content* with spaces, preserving line
    /// structure so reported line numbers stay accurate. String interpolation
    /// (`\(...)`) is real code and is preserved, not blanked, so unsafe constructs
    /// written inside interpolations are still detected. Understands raw string
    /// delimiters (`#"..."#`, `##"..."##`) and multiline strings (`"""..."""`), and
    /// block comments nest correctly (`/* /* */ */` is fully a comment).
    public static func stripCommentsAndStrings(_ s: String) -> String {
        let chars = Array(s)
        let n = chars.count
        var out = String()
        out.reserveCapacity(s.count)
        var i = 0
        var inLine = false
        var blockDepth = 0
        var stack: [Frame] = []

        func charAt(_ idx: Int) -> Character { idx < n ? chars[idx] : "\0" }

        func matchAt(_ idx: Int, _ pattern: [Character]) -> Bool {
            guard idx + pattern.count <= n else { return false }
            for k in 0..<pattern.count where chars[idx + k] != pattern[k] { return false }
            return true
        }

        func hashRun(at idx: Int) -> Int {
            var k = idx
            while k < n && chars[k] == "#" { k += 1 }
            return k - idx
        }

        // Parses a string-opening delimiter at `idx` (which must be `#` or `"`).
        // Returns (hashCount, isMultiline, delimiterLength), or nil if `idx` is not
        // actually the start of a string (e.g. `#` used by `#available`, `#if`, ...).
        func detectStringOpen(at idx: Int) -> (Int, Bool, Int)? {
            var idx2 = idx
            var hash = 0
            if charAt(idx2) == "#" {
                hash = hashRun(at: idx2)
                idx2 += hash
            }
            guard charAt(idx2) == "\"" else { return nil }
            if charAt(idx2 + 1) == "\"" && charAt(idx2 + 2) == "\"" {
                return (hash, true, hash + 3)
            }
            return (hash, false, hash + 1)
        }

        // Returns the length of the closing delimiter at `idx` for a frame with the
        // given hash count / multiline-ness, or nil if `idx` does not close it.
        func detectStringClose(at idx: Int, hash: Int, multiline: Bool) -> Int? {
            if multiline {
                guard matchAt(idx, ["\"", "\"", "\""]) else { return nil }
                if hash > 0 {
                    guard idx + 3 + hash <= n else { return nil }
                    for k in 0..<hash where chars[idx + 3 + k] != "#" { return nil }
                }
                return 3 + hash
            } else {
                guard charAt(idx) == "\"" else { return nil }
                if hash > 0 {
                    guard idx + 1 + hash <= n else { return nil }
                    for k in 0..<hash where chars[idx + 1 + k] != "#" { return nil }
                }
                return 1 + hash
            }
        }

        // Returns the length of a `\(` / `\#(` interpolation opener at `idx` for a
        // string with the given hash count, or nil if `idx` is not one (e.g. a
        // literal backslash inside a raw string, or an ordinary `\n` escape).
        func detectInterpOpen(at idx: Int, hash: Int) -> Int? {
            guard charAt(idx) == "\\" else { return nil }
            var k = idx + 1
            if hash > 0 {
                guard k + hash <= n else { return nil }
                for j in 0..<hash where chars[k + j] != "#" { return nil }
                k += hash
            }
            guard charAt(k) == "(" else { return nil }
            return (k + 1) - idx
        }

        while i < n {
            let c = chars[i]

            if inLine {
                if c == "\n" { inLine = false; out.append("\n") } else { out.append(" ") }
                i += 1; continue
            }
            if blockDepth > 0 {
                if c == "/" && charAt(i + 1) == "*" { blockDepth += 1; out += "  "; i += 2; continue }
                if c == "*" && charAt(i + 1) == "/" { blockDepth -= 1; out += "  "; i += 2; continue }
                out.append(c == "\n" ? "\n" : " "); i += 1; continue
            }

            if let top = stack.last, case .str(let hash, let multiline) = top {
                if let closeLen = detectStringClose(at: i, hash: hash, multiline: multiline) {
                    stack.removeLast()
                    out += String(repeating: " ", count: closeLen)
                    i += closeLen; continue
                }
                if c == "\\" {
                    if let interpLen = detectInterpOpen(at: i, hash: hash) {
                        stack.append(.interp(depth: 0))
                        out += String(repeating: " ", count: interpLen)
                        i += interpLen; continue
                    }
                    if hash == 0 {
                        // Ordinary escape (\", \\, \n, \u{...}, ...): blank it, but
                        // keep a genuine newline as a newline so line numbers do not
                        // drift if the escaped character happens to be one.
                        let escaped = charAt(i + 1)
                        out.append(" ")
                        out.append(escaped == "\n" ? "\n" : " ")
                        i += 2; continue
                    }
                    // Raw string: a bare `\` that isn't `\` + hash `#`s + `(` is a
                    // literal backslash, not an escape — consume just this char.
                    out.append(" "); i += 1; continue
                }
                out.append(c == "\n" ? "\n" : " "); i += 1; continue
            }

            // "Code mode": either true top level (stack empty) or inside a `\(...)`
            // interpolation (top of stack is `.interp`). Comments and new string
            // literals can both start here.
            if c == "/" && charAt(i + 1) == "/" { inLine = true; out += "  "; i += 2; continue }
            if c == "/" && charAt(i + 1) == "*" { blockDepth = 1; out += "  "; i += 2; continue }
            if c == "#" || c == "\"" {
                if let (hash, multiline, len) = detectStringOpen(at: i) {
                    stack.append(.str(hash: hash, multiline: multiline))
                    out += String(repeating: " ", count: len)
                    i += len; continue
                }
            }
            if let top = stack.last, case .interp(let depth) = top {
                if c == "(" {
                    stack[stack.count - 1] = .interp(depth: depth + 1)
                    out.append(c); i += 1; continue
                }
                if c == ")" {
                    if depth == 0 {
                        stack.removeLast()
                        out.append(" ")
                        i += 1; continue
                    }
                    stack[stack.count - 1] = .interp(depth: depth - 1)
                    out.append(c); i += 1; continue
                }
            }
            out.append(c); i += 1
        }
        return out
    }

    public static func scan(source: String, file: String) -> [UnsafeHit] {
        let cleaned = stripCommentsAndStrings(source)
        var hits: [UnsafeHit] = []
        for (idx, line) in cleaned.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var remaining = String(line)
            for construct in constructs where remaining.contains(construct) {
                hits.append(UnsafeHit(file: file, line: idx + 1, construct: construct))
                remaining = remaining.replacingOccurrences(of: construct, with: "")
            }
        }
        return hits
    }

    /// Only what this experiment introduced. Pre-existing unsafe is not the agent's doing.
    public static func newHits(baseline: [UnsafeHit], candidate: [UnsafeHit]) -> [UnsafeHit] {
        let known = Set(baseline.map { "\($0.file):\($0.line):\($0.construct)" })
        return candidate.filter { !known.contains("\($0.file):\($0.line):\($0.construct)") }
    }
}
