import Testing
@testable import AutoR3SearchKit

@Test func detectsTheDocumentedConstructs() {
    let src = """
    let p = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    let q = unsafeBitCast(x, to: Int.self)
    let r = unsafeDowncast(y, to: C.self)
    let s = raw.assumingMemoryBound(to: Int.self)
    extension T: @unchecked Sendable {}
    nonisolated(unsafe) var g = 0
    buf.withUnsafeMutableBufferPointer { _ in }
    """
    let hits = UnsafeDetector.scan(source: src, file: "A.swift")
    let found = Set(hits.map(\.construct))
    #expect(found.contains("UnsafeMutablePointer"))
    #expect(found.contains("unsafeBitCast"))
    #expect(found.contains("unsafeDowncast"))
    #expect(found.contains("assumingMemoryBound"))
    #expect(found.contains("@unchecked Sendable"))
    #expect(found.contains("nonisolated(unsafe)"))
    #expect(found.contains("withUnsafeMutableBufferPointer"))
}

@Test func ignoresMentionsInComments() {
    let src = """
    // we could use unsafeBitCast here but we do not
    /* UnsafeMutablePointer is tempting */
    let x = 1
    """
    #expect(UnsafeDetector.scan(source: src, file: "A.swift").isEmpty)
}

@Test func ignoresMentionsInStringLiterals() {
    let src = #"let msg = "do not use unsafeBitCast in this codebase""#
    #expect(UnsafeDetector.scan(source: src, file: "A.swift").isEmpty)
}

@Test func reportsAccurateLineNumbers() {
    let src = "let a = 1\nlet b = 2\nlet c = unsafeBitCast(x, to: Int.self)\n"
    let hits = UnsafeDetector.scan(source: src, file: "A.swift")
    #expect(hits.count == 1)
    #expect(hits[0].line == 3)
    #expect(hits[0].file == "A.swift")
}

@Test func onlyNewlyIntroducedHitsAreReported() {
    // Code that already used unsafe before the experiment is not the agent's doing.
    let base = [UnsafeHit(file: "A.swift", line: 3, construct: "unsafeBitCast")]
    let cand = [UnsafeHit(file: "A.swift", line: 3, construct: "unsafeBitCast"),
                UnsafeHit(file: "B.swift", line: 9, construct: "assumingMemoryBound")]
    #expect(UnsafeDetector.newHits(baseline: base, candidate: cand)
            == [UnsafeHit(file: "B.swift", line: 9, construct: "assumingMemoryBound")])
}

// MARK: - Gaps in the naive lexer named in the task brief.
//
// These are not part of the frozen five above; they pin down the direction each gap
// pushes detection (over- vs under-report) and confirm the fix.

@Test func rawStringBackslashDoesNotHideFollowingCode() {
    // `\` is not an escape character inside a raw string, so the string literal here
    // is exactly `a \` (closed by the matching `"#`), and `unsafeBitCast` afterward is
    // real code. A stripper that treats `\` as an escape unconditionally consumes the
    // closing `"` as if escaped, never finds the end of the string, and blanks the
    // rest of the file — an under-report (the costly direction).
    let src = "let s = #\"a \\\"# + unsafeBitCast(x, to: Int.self)"
    let hits = UnsafeDetector.scan(source: src, file: "A.swift")
    #expect(hits.map(\.construct) == ["unsafeBitCast"])
}

@Test func rawStringContentsAreStillIgnored() {
    let src = "let msg = #\"do not use unsafeBitCast in this codebase\"#"
    #expect(UnsafeDetector.scan(source: src, file: "A.swift").isEmpty)
}

@Test func multilineStringDoesNotDesyncOnEmbeddedQuotes() {
    // Unescaped quotes and `//`/`/*` inside a multiline string must not be mistaken
    // for the string's end, and must not leave later real code misclassified either
    // way (a naive one-quote-at-a-time stripper toggles unpredictably here).
    let src = #"""
    let s = """
    He said "hi // not a comment /* not a comment */" and left
    """
    let t = unsafeBitCast(x, to: Int.self)
    """#
    let hits = UnsafeDetector.scan(source: src, file: "A.swift")
    #expect(hits.map(\.construct) == ["unsafeBitCast"])
    #expect(hits[0].line == 4)
}

@Test func interpolationRevealsRealCode() {
    // String interpolation contains executable code, not string content. Blanking
    // the whole literal (as the naive stripper does) misses it — an under-report.
    let src = #"let s = "value: \(unsafeBitCast(x, to: Int.self))""#
    let hits = UnsafeDetector.scan(source: src, file: "A.swift")
    #expect(hits.map(\.construct) == ["unsafeBitCast"])
}

@Test func nestedBlockCommentsAreFullyStripped() {
    // Swift nests block comments. A stripper that exits on the first `*/` would treat
    // the text between the inner and outer close as real code — an over-report. This
    // implementation tracks nesting depth so the whole thing is one comment.
    let src = "/* outer /* inner */ unsafeBitCast(x, to: Int.self) still comment */\nlet x = 1"
    #expect(UnsafeDetector.scan(source: src, file: "A.swift").isEmpty)
}

@Test func stripCommentsAndStringsPreservesLineCount() {
    let src = ##"""
    // c1
    let s = """
    multi
    line "with quotes" and \(1 + 2)
    """
    let r = #"raw \#(1)"#
    /* block
       comment */
    let done = true
    """##
    let stripped = UnsafeDetector.stripCommentsAndStrings(src)
    #expect(stripped.split(separator: "\n", omittingEmptySubsequences: false).count
            == src.split(separator: "\n", omittingEmptySubsequences: false).count)
}
