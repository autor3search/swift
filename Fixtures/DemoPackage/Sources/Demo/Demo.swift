public func countWords(_ s: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for field in s.split(separator: " ") {
        var word = ""
        for ch in field where ch.isLetter || ch.isNumber {
            word = word + String(Character(ch.lowercased()))   // quadratic on purpose
        }
        if !word.isEmpty { counts[word, default: 0] += 1 }
    }
    return counts
}
