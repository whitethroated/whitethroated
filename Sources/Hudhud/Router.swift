import NIOCore
import NIOHTTP1

public typealias SyncHandler = @Sendable (
    Request
) -> Response

public typealias Handler = @Sendable (
    Request,
    Context
) -> EventLoopFuture<Response>

public typealias AsyncHandler = @Sendable (
    Request
) async throws -> Response

enum RouterMatch {
    case prepared(PreparedResponseStorage)
    case synchronous(
        SyncHandler,
        parameterNames: RouteParameterNames,
        parameterRanges: RouteParameterRanges
    )
    case asynchronous(
        Handler,
        parameterNames: RouteParameterNames,
        parameterRanges: RouteParameterRanges
    )
    case concurrent(
        AsyncHandler,
        parameterNames: RouteParameterNames,
        parameterRanges: RouteParameterRanges
    )
    case streaming(
        StreamingHandler,
        maxBodyBytes: Int?,
        parameterNames: RouteParameterNames,
        parameterRanges: RouteParameterRanges
    )
    case notFound
}

private enum RouteResponder {
    case synchronous(SyncHandler)
    case asynchronous(Handler)
    case concurrent(AsyncHandler)
    case streaming(
        StreamingHandler,
        maxBodyBytes: Int?
    )
    case prepared(PreparedResponseStorage)
}

private struct RouteEndpoint {
    let responder: RouteResponder
    let parameterNames: RouteParameterNames
}

private struct StaticEdge {
    let bytes: [UInt8]
    let node: RouterNode
}

private enum StaticBucket {
    case single(StaticEdge)
    case collisions([StaticEdge])

    @inline(__always)
    func matching<C: Collection>(
        _ bytes: C
    ) -> RouterNode? where C.Element == UInt8 {
        switch self {
        case .single(let edge):
            return Router.equals(
                edge.bytes,
                bytes
            )
            ? edge.node
            : nil

        case .collisions(let edges):
            for edge in edges
            where Router.equals(edge.bytes, bytes) {
                return edge.node
            }

            return nil
        }
    }

    func appending(_ edge: StaticEdge) -> StaticBucket {
        switch self {
        case .single(let existing):
            return .collisions([
                existing,
                edge
            ])

        case .collisions(var edges):
            edges.append(edge)
            return .collisions(edges)
        }
    }
}

private struct ExactStaticEdge {
    let bytes: [UInt8]
    let endpoint: RouteEndpoint
}

private enum ExactStaticBucket {
    case single(ExactStaticEdge)
    case collisions([ExactStaticEdge])

    @inline(__always)
    func matching<C: Collection>(
        _ bytes: C
    ) -> RouteEndpoint?
    where C.Element == UInt8 {
        switch self {
        case .single(let edge):
            return Router.equals(
                edge.bytes,
                bytes
            )
            ? edge.endpoint
            : nil

        case .collisions(let edges):
            for edge in edges
            where Router.equals(
                edge.bytes,
                bytes
            ) {
                return edge.endpoint
            }

            return nil
        }
    }

    func upserting(
        _ edge: ExactStaticEdge
    ) -> ExactStaticBucket {
        switch self {
        case .single(let existing):
            if Router.equals(
                existing.bytes,
                edge.bytes
            ) {
                return .single(edge)
            }

            return .collisions([
                existing,
                edge
            ])

        case .collisions(var edges):
            for index in edges.indices {
                if Router.equals(
                    edges[index].bytes,
                    edge.bytes
                ) {
                    edges[index] = edge
                    return .collisions(edges)
                }
            }

            edges.append(edge)
            return .collisions(edges)
        }
    }
}

private struct ExactStaticSlot {
    let hash: UInt64
    var bucket: ExactStaticBucket
}

private final class ExactStaticTable {
    private var slots:
        [ExactStaticSlot?]
    private var occupiedSlots = 0

    init(initialCapacity: Int = 8) {
        let capacity = Self.powerOfTwoCapacity(
            atLeast: max(8, initialCapacity)
        )

        self.slots = Array(
            repeating: nil,
            count: capacity
        )
    }

    var isEmpty: Bool {
        occupiedSlots == 0
    }

    func upsert(
        _ edge: ExactStaticEdge,
        hash: UInt64
    ) {
        if
            (occupiedSlots + 1) * 4
            >= slots.count * 3
        {
            resize()
        }

        insert(
            edge,
            hash: hash
        )
    }

    @inline(__always)
    func matching<C: Collection>(
        hash: UInt64,
        bytes: C
    ) -> RouteEndpoint?
    where C.Element == UInt8 {
        guard occupiedSlots > 0 else {
            return nil
        }

        let mask = slots.count - 1
        var index =
            Int(truncatingIfNeeded: hash)
            & mask

        for _ in 0..<slots.count {
            guard let slot = slots[index] else {
                return nil
            }

            if slot.hash == hash {
                return slot.bucket.matching(
                    bytes
                )
            }

            index = (index + 1) & mask
        }

        return nil
    }

    private func insert(
        _ edge: ExactStaticEdge,
        hash: UInt64
    ) {
        let mask = slots.count - 1
        var index =
            Int(truncatingIfNeeded: hash)
            & mask

        while true {
            if var slot = slots[index] {
                if slot.hash == hash {
                    slot.bucket =
                        slot.bucket.upserting(
                            edge
                        )
                    slots[index] = slot
                    return
                }

                index = (index + 1) & mask
                continue
            }

            slots[index] = ExactStaticSlot(
                hash: hash,
                bucket: .single(edge)
            )
            occupiedSlots += 1
            return
        }
    }

    private func resize() {
        let oldSlots = slots

        slots = Array(
            repeating: nil,
            count: oldSlots.count * 2
        )
        occupiedSlots = 0

        for slot in oldSlots {
            guard let slot else {
                continue
            }

            insert(
                slot.bucket,
                hash: slot.hash
            )
        }
    }

    private func insert(
        _ bucket: ExactStaticBucket,
        hash: UInt64
    ) {
        let mask = slots.count - 1
        var index =
            Int(truncatingIfNeeded: hash)
            & mask

        while slots[index] != nil {
            index = (index + 1) & mask
        }

        slots[index] = ExactStaticSlot(
            hash: hash,
            bucket: bucket
        )
        occupiedSlots += 1
    }

    private static func powerOfTwoCapacity(
        atLeast minimum: Int
    ) -> Int {
        var capacity = 1

        while capacity < minimum {
            capacity <<= 1
        }

        return capacity
    }
}

private final class RouterNode {
    var staticChildren: [UInt64: StaticBucket] = [:]
    var parameterChild: RouterNode?
    var catchAllChild: RouterNode?
    var endpoint: RouteEndpoint?
}

final class Router: @unchecked Sendable {
    private static let slash: UInt8 = 47
    private static let query: UInt8 = 63
    private static let hashOffset: UInt64 =
        14_695_981_039_346_656_037
    private static let hashPrime: UInt64 =
        1_099_511_628_211

    private(set) var hasStreamingRoutes = false
    private var streamingGet = false
    private var streamingPost = false
    private var streamingPut = false
    private var streamingPatch = false
    private var streamingDelete = false
    private var streamingHead = false
    private var streamingOptions = false
    private var streamingConnect = false
    private var streamingTrace = false
    private var streamingOtherMethods: Set<String> = []

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

    private let getExact = ExactStaticTable()
    private let postExact = ExactStaticTable()
    private let putExact = ExactStaticTable()
    private let patchExact = ExactStaticTable()
    private let deleteExact = ExactStaticTable()
    private let headExact = ExactStaticTable()
    private let optionsExact = ExactStaticTable()
    private let connectExact = ExactStaticTable()
    private let traceExact = ExactStaticTable()
    private var otherExact:
        [String: ExactStaticTable] = [:]

    func add(
        method: HTTPMethod,
        path: String,
        syncHandler: @escaping SyncHandler
    ) {
        insert(
            method: method,
            path: path,
            responder: .synchronous(syncHandler)
        )
    }

    func add(
        method: HTTPMethod,
        path: String,
        handler: @escaping Handler
    ) {
        insert(
            method: method,
            path: path,
            responder: .asynchronous(handler)
        )
    }

    func add(
        method: HTTPMethod,
        path: String,
        asyncHandler: @escaping AsyncHandler
    ) {
        insert(
            method: method,
            path: path,
            responder: .concurrent(asyncHandler)
        )
    }

    func add(
        method: HTTPMethod,
        path: String,
        streamingHandler: @escaping StreamingHandler,
        maxBodyBytes: Int?
    ) {
        hasStreamingRoutes = true
        markStreamingMethod(method)

        insert(
            method: method,
            path: path,
            responder: .streaming(
                streamingHandler,
                maxBodyBytes: maxBodyBytes
            )
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
            responder: .prepared(preparedResponse.storage)
        )
    }

    @inline(__always)
    func hasStreamingRoute(
        for method: NIOHTTP1.HTTPMethod
    ) -> Bool {
        switch method {
        case .GET:
            return streamingGet
        case .POST:
            return streamingPost
        case .PUT:
            return streamingPut
        case .PATCH:
            return streamingPatch
        case .DELETE:
            return streamingDelete
        case .HEAD:
            return streamingHead || streamingGet
        case .OPTIONS:
            return streamingOptions
        case .CONNECT:
            return streamingConnect
        case .TRACE:
            return streamingTrace
        case .RAW(let value):
            return streamingOtherMethods.contains(
                value
            )
        default:
            return streamingOtherMethods.contains(
                String(describing: method)
            )
        }
    }

    @inline(__always)
    func resolve(
        _ request: Request,
        context: Context
    ) -> ResponderResult {
        switch lookup(
            method: request.routingMethod,
            uri: request.routingBytes
        ) {
        case .prepared(let prepared):
            return .prepared(prepared)

        case .synchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            var matchedRequest = request
            matchedRequest.routeParameterNames =
                parameterNames
            matchedRequest.routeParameterRanges =
                parameterRanges

            return .immediate(
                handler(matchedRequest)
            )

        case .asynchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            var matchedRequest = request
            matchedRequest.routeParameterNames =
                parameterNames
            matchedRequest.routeParameterRanges =
                parameterRanges

            return .future(
                handler(
                    matchedRequest,
                    context
                )
            )

        case .concurrent(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            var matchedRequest = request
            matchedRequest.routeParameterNames =
                parameterNames
            matchedRequest.routeParameterRanges =
                parameterRanges

            let asyncRequest = matchedRequest
            let promise = context.eventLoop.makePromise(
                of: Response.self
            )
            promise.completeWithTask {
                try await handler(asyncRequest)
            }

            return .future(promise.futureResult)

        case .streaming(
            let handler,
            _,
            let parameterNames,
            let parameterRanges
        ):
            var matchedRequest = request
            matchedRequest.routeParameterNames =
                parameterNames
            matchedRequest.routeParameterRanges =
                parameterRanges

            let consumer = handler(
                StreamRequest(matchedRequest),
                context
            )
            let session = BodyStreamSession(
                consumer: consumer,
                eventLoop: context.eventLoop
            )
            context.streamingRegistration?
                .register(session)

            return .streaming(session)

        case .notFound:
            return .immediate(.notFound())
        }
    }

    @inline(__always)
    func lookup(
        method: NIOHTTP1.HTTPMethod,
        uri: String.UTF8View
    ) -> RouterMatch {
        switch method {
        case .GET:
            return lookup(
                exact: getExact,
                root: getRoot,
                uri: uri
            )

        case .POST:
            return lookup(
                exact: postExact,
                root: postRoot,
                uri: uri
            )

        case .PUT:
            return lookup(
                exact: putExact,
                root: putRoot,
                uri: uri
            )

        case .PATCH:
            return lookup(
                exact: patchExact,
                root: patchRoot,
                uri: uri
            )

        case .DELETE:
            return lookup(
                exact: deleteExact,
                root: deleteRoot,
                uri: uri
            )

        case .HEAD:
            return lookupHead(uri: uri)

        case .OPTIONS:
            return lookup(
                exact: optionsExact,
                root: optionsRoot,
                uri: uri
            )

        case .CONNECT:
            return lookup(
                exact: connectExact,
                root: connectRoot,
                uri: uri
            )

        case .TRACE:
            return lookup(
                exact: traceExact,
                root: traceRoot,
                uri: uri
            )

        default:
            return lookup(
                method: HTTPMethod(method),
                uri: uri
            )
        }
    }

    @inline(__always)
    func lookup(
        method: HTTPMethod,
        uri: String.UTF8View
    ) -> RouterMatch {
        switch method {
        case .get:
            return lookup(
                exact: getExact,
                root: getRoot,
                uri: uri
            )

        case .post:
            return lookup(
                exact: postExact,
                root: postRoot,
                uri: uri
            )

        case .put:
            return lookup(
                exact: putExact,
                root: putRoot,
                uri: uri
            )

        case .patch:
            return lookup(
                exact: patchExact,
                root: patchRoot,
                uri: uri
            )

        case .delete:
            return lookup(
                exact: deleteExact,
                root: deleteRoot,
                uri: uri
            )

        case .head:
            return lookupHead(uri: uri)

        case .options:
            return lookup(
                exact: optionsExact,
                root: optionsRoot,
                uri: uri
            )

        case .connect:
            return lookup(
                exact: connectExact,
                root: connectRoot,
                uri: uri
            )

        case .trace:
            return lookup(
                exact: traceExact,
                root: traceRoot,
                uri: uri
            )

        case .other(let value):
            if let exact = otherExact[value] {
                return lookup(
                    exact: exact,
                    root: otherRoots[value],
                    uri: uri
                )
            }

            if let match = trieMatch(
                root: otherRoots[value],
                uri: uri
            ) {
                return makeMatch(match)
            }

            return .notFound
        }
    }

    private func insert(
        method: HTTPMethod,
        path: String,
        responder: RouteResponder
    ) {
        precondition(
            !path.contains("//"),
            "Route path cannot contain repeated slashes"
        )
        precondition(
            !path.contains("?"),
            "Route path cannot contain a query string"
        )

        let root = rootForInsert(method)

        var node = root
        var parameterNames: RouteParameterNames = .none
        let segments = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        )

        for (index, segment) in segments.enumerated() {
            if segment.first == "*" {
                let name = String(segment.dropFirst())

                precondition(
                    !name.isEmpty,
                    "Catch-all parameter name cannot be empty"
                )
                precondition(
                    index == segments.index(before: segments.endIndex),
                    "Catch-all parameter must be the final route segment"
                )

                parameterNames.append(name)

                if let child = node.catchAllChild {
                    node = child
                } else {
                    let child = RouterNode()
                    node.catchAllChild = child
                    node = child
                }

                continue
            }

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

            if
                let bucket = node.staticChildren[hash],
                let child = bucket.matching(bytes)
            {
                node = child
                continue
            }

            let child = RouterNode()
            let edge = StaticEdge(
                bytes: bytes,
                node: child
            )

            if let bucket = node.staticChildren[hash] {
                node.staticChildren[hash] =
                    bucket.appending(edge)
            } else {
                node.staticChildren[hash] =
                    .single(edge)
            }

            node = child
        }

        let endpoint = RouteEndpoint(
            responder: responder,
            parameterNames: parameterNames
        )

        node.endpoint = endpoint

        if parameterNames.isEmpty {
            registerExactStatic(
                method: method,
                segments: segments,
                endpoint: endpoint
            )
        }
    }

    @inline(__always)
    private func lookup(
        exact: ExactStaticTable,
        root: RouterNode?,
        uri: String.UTF8View
    ) -> RouterMatch {
        if
            let endpoint = exactMatch(
                exact,
                uri: uri
            )
        {
            return makeMatch(endpoint)
        }

        if let match = trieMatch(
            root: root,
            uri: uri
        ) {
            return makeMatch(match)
        }

        return .notFound
    }

    @inline(__always)
    private func lookupHead(
        uri: String.UTF8View
    ) -> RouterMatch {
        if
            let endpoint = exactMatch(
                headExact,
                uri: uri
            )
        {
            return makeMatch(endpoint)
        }

        if let match = trieMatch(
            root: headRoot,
            uri: uri
        ) {
            return makeMatch(match)
        }

        if
            let endpoint = exactMatch(
                getExact,
                uri: uri
            )
        {
            return makeMatch(endpoint)
        }

        if let match = trieMatch(
            root: getRoot,
            uri: uri
        ) {
            return makeMatch(match)
        }

        return .notFound
    }

    @inline(__always)
    private func trieMatch(
        root: RouterNode?,
        uri: String.UTF8View
    ) -> (
        endpoint: RouteEndpoint,
        parameterRanges: RouteParameterRanges
    )? {
        guard let root else {
            return nil
        }

        if let contiguous = uri
            .withContiguousStorageIfAvailable({
                bytes in

                match(
                    uri: bytes,
                    from: root
                )
            })
        {
            return contiguous
        }

        return match(
            uri: uri,
            from: root
        )
    }

    @inline(__always)
    private func makeMatch(
        _ endpoint: RouteEndpoint
    ) -> RouterMatch {
        makeMatch((
            endpoint: endpoint,
            parameterRanges: .none
        ))
    }

    @inline(__always)
    private func makeMatch(
        _ match: (
            endpoint: RouteEndpoint,
            parameterRanges: RouteParameterRanges
        )
    ) -> RouterMatch {
        switch match.endpoint.responder {
        case .prepared(let prepared):
            return .prepared(prepared)

        case .synchronous(let handler):
            return .synchronous(
                handler,
                parameterNames:
                    match.endpoint.parameterNames,
                parameterRanges:
                    match.parameterRanges
            )

        case .asynchronous(let handler):
            return .asynchronous(
                handler,
                parameterNames:
                    match.endpoint.parameterNames,
                parameterRanges:
                    match.parameterRanges
            )

        case .concurrent(let handler):
            return .concurrent(
                handler,
                parameterNames:
                    match.endpoint.parameterNames,
                parameterRanges:
                    match.parameterRanges
            )

        case .streaming(
            let handler,
            let maxBodyBytes
        ):
            return .streaming(
                handler,
                maxBodyBytes: maxBodyBytes,
                parameterNames:
                    match.endpoint.parameterNames,
                parameterRanges:
                    match.parameterRanges
            )
        }
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

    private func markStreamingMethod(
        _ method: HTTPMethod
    ) {
        switch method {
        case .get:
            streamingGet = true
        case .post:
            streamingPost = true
        case .put:
            streamingPut = true
        case .patch:
            streamingPatch = true
        case .delete:
            streamingDelete = true
        case .head:
            streamingHead = true
        case .options:
            streamingOptions = true
        case .connect:
            streamingConnect = true
        case .trace:
            streamingTrace = true
        case .other(let value):
            streamingOtherMethods.insert(value)
        }
    }

    private func registerExactStatic(
        method: HTTPMethod,
        segments: [Substring],
        endpoint: RouteEndpoint
    ) {
        var bytes: [UInt8] = [Self.slash]

        for index in segments.indices {
            if index != segments.startIndex {
                bytes.append(Self.slash)
            }

            bytes.append(
                contentsOf: segments[index].utf8
            )
        }

        let edge = ExactStaticEdge(
            bytes: bytes,
            endpoint: endpoint
        )
        let hash = Self.hash(bytes)

        let table: ExactStaticTable

        switch method {
        case .get:
            table = getExact

        case .post:
            table = postExact

        case .put:
            table = putExact

        case .patch:
            table = patchExact

        case .delete:
            table = deleteExact

        case .head:
            table = headExact

        case .options:
            table = optionsExact

        case .connect:
            table = connectExact

        case .trace:
            table = traceExact

        case .other(let value):
            if let existing =
                otherExact[value]
            {
                table = existing
            } else {
                let created =
                    ExactStaticTable()
                otherExact[value] = created
                table = created
            }
        }

        table.upsert(
            edge,
            hash: hash
        )
    }

    @inline(__always)
    private func exactMatch(
        _ table: ExactStaticTable,
        uri: String.UTF8View
    ) -> RouteEndpoint? {
        guard !table.isEmpty else {
            return nil
        }

        if let contiguous = uri
            .withContiguousStorageIfAvailable({
                bytes in

                exactMatch(
                    table,
                    bytes: bytes
                )
            })
        {
            return contiguous
        }

        return exactMatch(
            table,
            bytes: uri
        )
    }

    @inline(__always)
    private func exactMatch<C: Collection>(
        _ table: ExactStaticTable,
        bytes: C
    ) -> RouteEndpoint?
    where C.Element == UInt8 {
        var cursor = bytes.startIndex
        var hash = Self.hashOffset

        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            if byte == Self.query {
                break
            }

            hash ^= UInt64(byte)
            hash &*= Self.hashPrime
            bytes.formIndex(after: &cursor)
        }

        return table.matching(
            hash: hash,
            bytes:
                bytes[
                    bytes.startIndex..<cursor
                ]
        )
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

    private func match<C: Collection>(
        uri: C,
        from root: RouterNode
    ) -> (
        endpoint: RouteEndpoint,
        parameterRanges: RouteParameterRanges
    )? where C.Element == UInt8 {
        var parameterRanges: RouteParameterRanges = .none

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
        parameterRanges: inout RouteParameterRanges
    ) -> RouteEndpoint? where C.Element == UInt8 {
        var cursor = initialCursor
        var cursorOffset = initialOffset

        if
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

        if
            node.staticChildren.isEmpty,
            node.parameterChild == nil,
            let catchAllChild = node.catchAllChild,
            let endpoint = catchAllChild.endpoint
        {
            while
                cursor != bytes.endIndex,
                bytes[cursor] != Self.query
            {
                bytes.formIndex(after: &cursor)
                cursorOffset += 1
            }

            parameterRanges.append(
                segmentStartOffset..<cursorOffset
            )

            return endpoint
        }

        var segmentHash = Self.hashOffset

        if node.staticChildren.isEmpty {
            while cursor != bytes.endIndex {
                let byte = bytes[cursor]

                if byte == Self.slash || byte == Self.query {
                    break
                }

                bytes.formIndex(after: &cursor)
                cursorOffset += 1
            }
        } else {
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

            if
                let bucket = node.staticChildren[segmentHash],
                let staticChild = bucket.matching(segment)
            {
                if
                    cursor == bytes.endIndex
                    || bytes[cursor] == Self.query
                {
                    if let endpoint = staticChild.endpoint {
                        return endpoint
                    }
                } else if let endpoint = matchNode(
                    staticChild,
                    bytes: bytes,
                    cursor: cursor,
                    cursorOffset: cursorOffset,
                    parameterRanges: &parameterRanges
                ) {
                    return endpoint
                }
            }
        }

        if let parameterChild = node.parameterChild {
            parameterRanges.append(
                segmentStartOffset..<cursorOffset
            )

            if
                cursor == bytes.endIndex
                || bytes[cursor] == Self.query
            {
                if let endpoint = parameterChild.endpoint {
                    return endpoint
                }
            } else if let endpoint = matchNode(
                parameterChild,
                bytes: bytes,
                cursor: cursor,
                cursorOffset: cursorOffset,
                parameterRanges: &parameterRanges
            ) {
                return endpoint
            }

            parameterRanges.removeLast()
        }

        guard
            let catchAllChild = node.catchAllChild,
            let endpoint = catchAllChild.endpoint
        else {
            return nil
        }

        while
            cursor != bytes.endIndex,
            bytes[cursor] != Self.query
        {
            bytes.formIndex(after: &cursor)
            cursorOffset += 1
        }

        parameterRanges.append(
            segmentStartOffset..<cursorOffset
        )

        return endpoint
    }

    @inline(__always)
    fileprivate static func equals<C: Collection>(
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
