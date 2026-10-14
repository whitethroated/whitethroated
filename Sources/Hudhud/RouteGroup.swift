public struct RouteGroup: Sendable {
    private let application: Application
    public let prefix: String

    init(
        application: Application,
        prefix: String
    ) {
        self.application = application
        self.prefix = Self.normalize(prefix)
    }

    public func group(_ path: String) -> RouteGroup {
        RouteGroup(
            application: application,
            prefix: joined(path)
        )
    }

    public func all(
        _ path: String,
        response: PreparedResponse
    ) {
        application.all(
            joined(path),
            response: response
        )
    }

    public func all(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.all(
            joined(path),
            use: handler
        )
    }

    public func all(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.all(
            joined(path),
            use: handler
        )
    }

    public func all(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.all(
            joined(path),
            use: handler
        )
    }

    public func onStream(
        _ method: HTTPMethod,
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        application.onStream(
            method,
            joined(path),
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        response: PreparedResponse
    ) {
        application.on(
            method,
            joined(path),
            response: response
        )
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.on(
            method,
            joined(path),
            use: handler
        )
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.on(
            method,
            joined(path),
            use: handler
        )
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.on(
            method,
            joined(path),
            use: handler
        )
    }

    public func get(
        _ path: String,
        response: PreparedResponse
    ) {
        application.get(
            joined(path),
            response: response
        )
    }

    public func get(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.get(
            joined(path),
            use: handler
        )
    }

    public func get(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.get(
            joined(path),
            use: handler
        )
    }

    public func get(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.get(
            joined(path),
            use: handler
        )
    }

    public func postStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        application.postStream(
            joined(path),
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
    }

    public func post(
        _ path: String,
        response: PreparedResponse
    ) {
        application.post(
            joined(path),
            response: response
        )
    }

    public func post(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.post(
            joined(path),
            use: handler
        )
    }

    public func post(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.post(
            joined(path),
            use: handler
        )
    }

    public func post(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.post(
            joined(path),
            use: handler
        )
    }

    public func putStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        application.putStream(
            joined(path),
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
    }

    public func put(
        _ path: String,
        response: PreparedResponse
    ) {
        application.put(
            joined(path),
            response: response
        )
    }

    public func put(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.put(
            joined(path),
            use: handler
        )
    }

    public func put(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.put(
            joined(path),
            use: handler
        )
    }

    public func put(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.put(
            joined(path),
            use: handler
        )
    }

    public func patchStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        application.patchStream(
            joined(path),
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
    }

    public func patch(
        _ path: String,
        response: PreparedResponse
    ) {
        application.patch(
            joined(path),
            response: response
        )
    }

    public func patch(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.patch(
            joined(path),
            use: handler
        )
    }

    public func patch(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.patch(
            joined(path),
            use: handler
        )
    }

    public func patch(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.patch(
            joined(path),
            use: handler
        )
    }

    public func deleteStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        application.deleteStream(
            joined(path),
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
    }

    public func delete(
        _ path: String,
        response: PreparedResponse
    ) {
        application.delete(
            joined(path),
            response: response
        )
    }

    public func delete(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.delete(
            joined(path),
            use: handler
        )
    }

    public func delete(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.delete(
            joined(path),
            use: handler
        )
    }

    public func delete(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.delete(
            joined(path),
            use: handler
        )
    }

    public func head(
        _ path: String,
        response: PreparedResponse
    ) {
        application.head(
            joined(path),
            response: response
        )
    }

    public func head(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.head(
            joined(path),
            use: handler
        )
    }

    public func head(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.head(
            joined(path),
            use: handler
        )
    }

    public func head(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.head(
            joined(path),
            use: handler
        )
    }

    public func options(
        _ path: String,
        response: PreparedResponse
    ) {
        application.options(
            joined(path),
            response: response
        )
    }

    public func options(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.options(
            joined(path),
            use: handler
        )
    }

    public func options(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.options(
            joined(path),
            use: handler
        )
    }

    public func options(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.options(
            joined(path),
            use: handler
        )
    }

    public func connect(
        _ path: String,
        response: PreparedResponse
    ) {
        application.connect(
            joined(path),
            response: response
        )
    }

    public func connect(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.connect(
            joined(path),
            use: handler
        )
    }

    public func connect(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.connect(
            joined(path),
            use: handler
        )
    }

    public func connect(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.connect(
            joined(path),
            use: handler
        )
    }

    public func trace(
        _ path: String,
        response: PreparedResponse
    ) {
        application.trace(
            joined(path),
            response: response
        )
    }

    public func trace(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        application.trace(
            joined(path),
            use: handler
        )
    }

    public func trace(
        _ path: String,
        use handler: @escaping Handler
    ) {
        application.trace(
            joined(path),
            use: handler
        )
    }

    public func trace(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        application.trace(
            joined(path),
            use: handler
        )
    }

    private func joined(_ path: String) -> String {
        let normalizedPath = Self.normalize(path)

        if prefix == "/" {
            return normalizedPath
        }

        if normalizedPath == "/" {
            return prefix
        }

        return prefix + normalizedPath
    }

    private static func normalize(
        _ path: String
    ) -> String {
        guard !path.isEmpty else {
            return "/"
        }

        var value = path

        if !value.hasPrefix("/") {
            value = "/" + value
        }

        while
            value.count > 1,
            value.hasSuffix("/")
        {
            value.removeLast()
        }

        return value
    }
}
