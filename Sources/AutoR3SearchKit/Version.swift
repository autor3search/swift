public enum BuildInfo {
    public static let version = "0.1.0"

    /// A results.tsv row is only as reproducible as the binary that wrote it.
    public static func describe(gitDescribe: String?, dirty: Bool) -> String {
        guard let gitDescribe else { return version }
        return dirty ? "\(gitDescribe) (dirty)" : gitDescribe
    }
}
