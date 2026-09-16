import Testing
@testable import AutoR3SearchKit

// Input is real `sample` output captured on this machine during the spike
// (Task 20 brief, verbatim).
private let realSample = """
Call graph:
    1581 main  (in spin) + 248  [0x100488898]  spin.swift:6
      79 main  (in spin) + 252  [0x10048889c]  spin.swift:6
      10 main  (in spin) + 252,228,...  [0x10048889c,0x100488884,...]  spin.swift:6
      42 other (in spin) + 100  [0x100488900]  other.swift:17
"""

@Test func aggregatesSamplesByFileAndLine() {
    let hot = Sampler.parseSampleOutput(realSample)
    #expect(hot.first == HotLine(file: "spin.swift", line: 6, samples: 1670))
}

@Test func ranksHottestFirst() {
    let hot = Sampler.parseSampleOutput(realSample)
    #expect(hot.map(\.samples) == [1670, 42])
}

@Test func toleratesOutputWithNoAttributableFrames() {
    #expect(Sampler.parseSampleOutput("Call graph:\n  nothing useful\n").isEmpty)
}
