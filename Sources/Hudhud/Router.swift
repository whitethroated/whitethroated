import NIOCore

public typealias Handler = @Sendable (Request, Context) -> EventLoopFuture<Response>

private struct RouteEndpoint {
    let handler: Handler
    let parameterNames: [String]
}

private struct StaticEdge {
    let bytes: [UInt8]
    let node: RouterNode
}

private final class RouterNode {
    var staticChildren: [UInt64: [StaticEdge]] = [:]
    var parameterChild: RouterNode?
    var endpoint: RouteEndpoint?
}

final class Router: @unchecked Sendable {
    private var roots: [HTTPMethod: RouterNode] = [:]

    func add(
        method: HTTPMethod,
        path: String,
        handler: @escaping Handler
    ) {
        let root = roots[method] ?? {
            let node = RouterNode()
            roots[method] = node
            return node
        }()

        var node = root
        var parameterNames: [String] = []

        for segment in path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            if segment.first == ":" {
                let name = String(segment.dropFirst())
                precondition(
                    !name.isEmpty,
                    "Route parameter name cannot be empty"
                )

                parameterNames.append(name)

                if let child = node.parameterChild {
                    node = child
                } else {
                    let child = RouterNode()
                    node.parameterChild = child
                    node = child
                }

                continue
            }

            let bytes = Array(segment.utf8)
            let hash = Self.hash(bytes)

            if let child = Self.findStaticChild(
                in: node,
                hash: hash,
                matching: bytes
            ) {
                node = child
                continue
            }

            let child = RouterNode()
            let edge = StaticEdge(bytes: bytes, node: child)
            node.staticChildren[hash, default: []].append(edge)
            node = child
        }

        node.endpoint = RouteEndpoint(
            handler: handler,
            parameterNames: parameterNames
        )
    }

    func resolve(
        _ request: Request,
        context: Context
    ) -> EventLoopFuture<Response> {
        guard
            let root = roots[request.method],
            let match = match(path: request.path, from: root)
        else {
            return context.eventLoop.makeSucceededFuture(.notFound())
        }

        var matchedRequest = request

        if !match.endpoint.parameterNames.isEmpty {
            var parameters: [String: String] = [:]
            parameters.reserveCapacity(match.endpoint.parameterNames.count)

            for (name, value) in zip(
                match.endpoint.parameterNames,
                match.parameterValues
            ) {
                parameters[name] = value
            }

            matchedRequest.parameters = parameters
        }

        return match.endpoint.handler(matchedRequest, context)
    }

    private func match(
        path: String,
        from root: RouterNode
    ) -> (
        endpoint: RouteEndpoint,
        parameterValues: [String]
    )? {
        let bytes = path.utf8
        var cursor = bytes.startIndex
        var node = root
        var parameterValues: [String] = []

        while cursor != bytes.endIndex {
            while cursor != bytes.endIndex, bytes[cursor] == 47 {
                bytes.formIndex(after: &cursor)
            }

            guard cursor != bytes.endIndex else {
                break
            }

            let segmentStart = cursor

            while cursor != bytes.endIndex, bytes[cursor] != 47 {
                bytes.formIndex(after: &cursor)
            }

            let segment = bytes[segmentStart..<cursor]
            let segmentHash = Self.hash(segment)

            if let child = Self.findStaticChild(
                in: node,
                hash: segmentHash,
                matching: segment
            ) {
                node = child
                continue
            }

            guard let parameterChild = node.parameterChild else {
                return nil
            }

            parameterValues.append(
                String(decoding: segment, as: UTF8.self)
            )
            node = parameterChild
        }

        guard let endpoint = node.endpoint else {
            return nil
        }

        return (endpoint, parameterValues)
    }

    @inline(__always)
    private static func findStaticChild<C: Collection>(
        in node: RouterNode,
        hash: UInt64,
        matching bytes: C
    ) -> RouterNode? where C.Element == UInt8 {
        guard let candidates = node.staticChildren[hash] else {
            return nil
        }

        for candidate in candidates where equals(candidate.bytes, bytes) {
            return candidate.node
        }

        return nil
    }

    @inline(__always)
    private static func equals<C: Collection>(
        _ lhs: [UInt8],
        _ rhs: C
    ) -> Bool where C.Element == UInt8 {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex

        while
            leftIndex != lhs.endIndex,
            rightIndex != rhs.endIndex
        {
            guard lhs[leftIndex] == rhs[rightIndex] else {
                return false
            }

            lhs.formIndex(after: &leftIndex)
            rhs.formIndex(after: &rightIndex)
        }

        return leftIndex == lhs.endIndex && rightIndex == rhs.endIndex
    }

    @inline(__always)
    private static func hash<C: Collection>(
        _ bytes: C
    ) -> UInt64 where C.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037

        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        return hash
    }
}
