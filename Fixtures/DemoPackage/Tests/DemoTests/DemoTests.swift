import Testing
@testable import Demo

@Test func countsWordsCaseInsensitively() {
    #expect(countWords("the quick brown the") == ["the": 2, "quick": 1, "brown": 1])
}

@Test func stripsPunctuation() {
    #expect(countWords("Hello, WORLD! hello?") == ["hello": 2, "world": 1])
}
