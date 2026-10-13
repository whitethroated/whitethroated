import NIOCore

public typealias Handler = @Sendable (
    Request,
    Context
) -> EventLoopFuture<Response>

private enum RouteResponder {
    case handler(InternalHandler)
    case prepared(PreparedResponse)
}

private struct RouteEndpoint {
    let responder: RouteResponder
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
    private static let slash: UInt8 = 47
    private static let query: UInt8 = 63
    private static let hashOffset: UInt64 =
        14_695_981_039_346_656_037
    private static let hashPrime: UInt64 =
        1_099_511_628_211

    private var getRoot: RouterNode?
    private var postRoot: RouterNode?
    private var putRoot: RouterNode?
    private var patchRoot: RouterNode?
    private var deleteRoot: RouterNode?
    private var headRoot: RouterNode?
    private var optionsRoot: RouterNode?
    private var connectRoot: RouterNode?
    private var traceRoot: RouterNode?
    private var otherRoots: [String: RouterNode] = [:]

    func add(
        method: HTTPMethod,
        path: String,
        handler: @escaping InternalHandler
    ) {
        insert(
            method: method,
            path: path,
            responder: .handler(handler)
        )
    }

    func add(
        method: HTTPMethod,
        path: String,
        preparedResponse: PreparedResponse
    ) {
        insert(
            method: method,
            path: path,
            responder: .prepared(preparedResponse)
        )
    }

    @inline(__always)
    func resolve(
        _ request: Request,
        context: Context
    ) -> ResponderResult {
        if
            let root = root(for: request.method),
            let match = match(
                uri: request.routingBytes,
                from: root
            )
        {
            return invoke(
                match.endpoint,
                parameterRanges: match.parameterRanges,
                request: request,
                context: context
            )
        }

        if
            request.method == .head,
            let root = getRoot,
            let match = match(
                uri: request.routingBytes,
                from: root
            )
        {
            return invoke(
                match.endpoint,
                parameterRanges: match.parameterRanges,
                request: request,
                context: context
            )
        }

        return .immediate(.notFound())
    }

    private func insert(
        method: HTTPMethod,
        path: String,
        responder: RouteResponder
    ) {
        let root = rootForInsert(method)

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
            let edge = StaticEdge(
                bytes: bytes,
                node: child
            )
            node.staticChildren[hash, default: []].append(edge)
            node = child
        }

        node.endpoint = RouteEndpoint(
            responder: responder,
            parameterNames: parameterNames
        )
    }

    @inline(__always)
    private func root(
        for method: HTTPMethod
    ) -> RouterNode? {
        switch method {
        case .get:
            return getRoot
        case .post:
            return postRoot
        case .put:
            return putRoot
        case .patch:
            return patchRoot
        case .delete:
            return deleteRoot
        case .head:
            return headRoot
        case .options:
            return optionsRoot
        case .connect:
            return connectRoot
        case .trace:
            return traceRoot
        case .other(let value):
            return otherRoots[value]
        }
    }

    private func rootForInsert(
        _ method: HTTPMethod
    ) -> RouterNode {
        if let existing = root(for: method) {
            return existing
        }

        let node = RouterNode()

        switch method {
        case .get:
            getRoot = node
        case .post:
            postRoot = node
        case .put:
            putRoot = node
        case .patch:
            patchRoot = node
        case .delete:
            deleteRoot = node
        case .head:
            headRoot = node
        case .options:
            optionsRoot = node
        case .connect:
            connectRoot = node
        case .trace:
            traceRoot = node
        case .other(let value):
            otherRoots[value] = node
        }

        return node
    }

    @inline(__always)
    private func invoke(
        _ endpoint: RouteEndpoint,
        parameterRanges: [Range<Int>],
        request: Request,
        context: Context
    ) -> ResponderResult {
        switch endpoint.responder {
        case .prepared(let prepared):
            return .prepared(prepared)

        case .handler(let handler):
            var matchedRequest = request
            matchedRequest.routeParameterNames =
                endpoint.parameterNames
            matchedRequest.routeParameterRanges =
                parameterRanges

            return handler(
                matchedRequest,
                context
            )
        }
    }

    private func match<C: Collection>(
        uri: C,
        from root: RouterNode
    ) -> (
        endpoint: RouteEndpoint,
        parameterRanges: [Range<Int>]
    )? where C.Element == UInt8 {
        var parameterRanges: [Range<Int>] = []

        guard let endpoint = matchNode(
            root,
            bytes: uri,
            cursor: uri.startIndex,
            cursorOffset: 0,
            parameterRanges: &parameterRanges
        ) else {
            return nil
        }

        return (endpoint, parameterRanges)
    }

    @inline(__always)
    private func matchNode<C: Collection>(
        _ node: RouterNode,
        bytes: C,
        cursor initialCursor: C.Index,
        cursorOffset initialOffset: Int,
        parameterRanges: inout [Range<Int>]
    ) -> RouteEndpoint? where C.Element == UInt8 {
        var cursor = initialCursor
        var cursorOffset = initialOffset

        while
            cursor != bytes.endIndex,
            bytes[cursor] == Self.slash
        {
            bytes.formIndex(after: &cursor)
            cursorOffset += 1
        }

        if cursor == bytes.endIndex {
            return node.endpoint
        }

        if bytes[cursor] == Self.query {
            return node.endpoint
        }

        let segmentStart = cursor
        let segmentStartOffset = cursorOffset
        var segmentHash = Self.hashOffset

        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            if byte == Self.slash || byte == Self.query {
                break
            }

            segmentHash ^= UInt64(byte)
            segmentHash &*= Self.hashPrime
            bytes.formIndex(after: &cursor)
            cursorOffset += 1
        }

        let segment = bytes[segmentStart..<cursor]

        if let staticChild = Self.findStaticChild(
            in: node,
            hash: segmentHash,
            matching: segment
        ), let endpoint = matchNode(
            staticChild,
            bytes: bytes,
            cursor: cursor,
            cursorOffset: cursorOffset,
            parameterRanges: &parameterRanges
        ) {
            return endpoint
        }

        guard let parameterChild = node.parameterChild else {
            return nil
        }

        parameterRanges.append(
            segmentStartOffset..<cursorOffset
        )

        if let endpoint = matchNode(
            parameterChild,
            bytes: bytes,
            cursor: cursor,
            cursorOffset: cursorOffset,
            parameterRanges: &parameterRanges
        ) {
            return endpoint
        }

        parameterRanges.removeLast()
        return nil
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

        for candidate in candidates
        where equals(candidate.bytes, bytes) {
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

        return leftIndex == lhs.endIndex
            && rightIndex == rhs.endIndex
    }

    @inline(__always)
    private static func hash<C: Collection>(
        _ bytes: C
    ) -> UInt64 where C.Element == UInt8 {
        var hash = Self.hashOffset

        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= Self.hashPrime
        }

        return hash
    }
}
