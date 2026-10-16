extension Response {
    public mutating func setHeader(
        _ name: String,
        _ value: String
    ) {
        headers.replaceOrAdd(
            name: name,
            value: value
        )
    }

    public mutating func appendHeader(
        _ name: String,
        _ value: String
    ) {
        headers.add(
            name: name,
            value: value
        )
    }

    public func header(
        _ name: String,
        _ value: String
    ) -> Response {
        var copy = self
        copy.setHeader(name, value)
        return copy
    }
}
