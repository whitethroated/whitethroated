public enum DatabaseIdentifier {
    /// Quote a single SQL identifier using standard double quotes.
    ///
    /// The value is expected to come from application schema configuration, not
    /// from request input. Quoting still escapes embedded double quotes and
    /// rejects NUL bytes so a configuration mistake cannot split a statement.
    public static func quote(
        _ identifier: String
    ) -> String {
        precondition(
            !identifier.isEmpty,
            "SQL identifier must not be empty"
        )
        precondition(
            !identifier.utf8.contains(0),
            "SQL identifier must not contain a NUL byte"
        )

        let escaped =
            identifier.replacingOccurrences(
                of: "\"",
                with: "\"\""
            )

        return "\"\(escaped)\""
    }

    public static func quote(
        _ identifiers: [String]
    ) -> String {
        identifiers
            .map {
                quote($0)
            }
            .joined(separator: ", ")
    }
}
