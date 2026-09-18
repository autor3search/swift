public enum Combinatorics {
    /// Multiplicative form, kept in Double to stay exact for the sizes we use
    /// (C(20,10) = 184756 is far inside Double's exact-integer range).
    public static func binomial(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        let k = min(k, n - k)
        var result = 1.0
        for i in 0..<k { result = result * Double(n - i) / Double(i + 1) }
        return (result).rounded()
    }
}
