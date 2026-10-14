import NIOCore

public struct ServerSentEvent: Sendable {
    public var data: String
    public var event: String?
    public var id: String?
    public var retryMilliseconds: Int?

    public init(
        data: String,
        event: String? = nil,
        id: String? = nil,
        retryMilliseconds: Int? = nil
    ) {
        if let event {
            precondition(
                !Self.containsLineBreak(event),
                "SSE event name cannot contain line breaks"
            )
        }

        if let id {
            precondition(
                !Self.containsLineBreak(id),
                "SSE id cannot contain line breaks"
            )
        }

        if let retryMilliseconds {
            precondition(
                retryMilliseconds >= 0,
                "SSE retryMilliseconds must be zero or greater"
            )
        }

        self.data = data
        self.event = event
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }

    internal var estimatedSerializedBytes: Int {
        var count = data.utf8.count + 8

        if let event {
            count += event.utf8.count + 8
        }

        if let id {
            count += id.utf8.count + 5
        }

        if retryMilliseconds != nil {
            count += 24
        }

        return count
    }

    internal func write(
        to buffer: inout ByteBuffer
    ) {
        if let event {
            buffer.writeStaticString("event: ")
            buffer.writeString(event)
            buffer.writeInteger(UInt8(10))
        }

        if let id {
            buffer.writeStaticString("id: ")
            buffer.writeString(id)
            buffer.writeInteger(UInt8(10))
        }

        if let retryMilliseconds {
            buffer.writeStaticString("retry: ")
            buffer.writeString(
                String(retryMilliseconds)
            )
            buffer.writeInteger(UInt8(10))
        }

        writeData(to: &buffer)
        buffer.writeInteger(UInt8(10))
    }

    internal func serialized() -> String {
        var buffer = ByteBufferAllocator().buffer(
            capacity: estimatedSerializedBytes
        )
        write(to: &buffer)

        return buffer.getString(
            at: buffer.readerIndex,
            length: buffer.readableBytes
        ) ?? ""
    }

    private func writeData(
        to buffer: inout ByteBuffer
    ) {
        let bytes = data.utf8
        var lineStart = bytes.startIndex
        var cursor = bytes.startIndex

        buffer.writeStaticString("data: ")

        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            guard byte == 10 || byte == 13 else {
                bytes.formIndex(after: &cursor)
                continue
            }

            buffer.writeBytes(
                bytes[lineStart..<cursor]
            )
            buffer.writeInteger(UInt8(10))

            if byte == 13 {
                let next = bytes.index(after: cursor)

                if
                    next != bytes.endIndex,
                    bytes[next] == 10
                {
                    cursor = next
                }
            }

            bytes.formIndex(after: &cursor)
            lineStart = cursor
            buffer.writeStaticString("data: ")
        }

        buffer.writeBytes(
            bytes[lineStart..<bytes.endIndex]
        )
        buffer.writeInteger(UInt8(10))
    }

    @inline(__always)
    private static func containsLineBreak(
        _ value: String
    ) -> Bool {
        value.utf8.contains(10)
            || value.utf8.contains(13)
    }
}

extension ResponseStreamWriter {
    @discardableResult
    public func writeSSE(
        _ event: ServerSentEvent,
        flush: Bool = true
    ) -> EventLoopFuture<Void> {
        var buffer = makeBuffer(
            capacity:
                event.estimatedSerializedBytes
        )
        event.write(to: &buffer)

        if flush {
            return writeAndFlush(buffer)
        }

        return write(buffer)
    }
}
