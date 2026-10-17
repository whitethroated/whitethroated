import WhiteThroatedRuntime

extension Response {
    public mutating func setHeader(
        _ name: String,
        _ value: String
    ) {
        let preserveContentLength =
            contentLengthIsNormalized
            && !HTTPContentLength
                .isContentLengthName(name)

        headers.replaceOrAdd(
            name: name,
            value: value
        )

        if preserveContentLength {
            contentLengthIsNormalized = true
        }
    }

    public mutating func appendHeader(
        _ name: String,
        _ value: String
    ) {
        let preserveContentLength =
            contentLengthIsNormalized
            && !HTTPContentLength
                .isContentLengthName(name)

        headers.add(
            name: name,
            value: value
        )

        if preserveContentLength {
            contentLengthIsNormalized = true
        }
    }

    public consuming func header(
        _ name: String,
        _ value: String
    ) -> Response {
        self.setHeader(
            name,
            value
        )
        return self
    }
}
