import Foundation
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

    internal func serialized() -> String {
        var output = ""

        if let event {
            output += "event: \(event)\n"
        }

        if let id {
            output += "id: \(id)\n"
        }

        if let retryMilliseconds {
            output += "retry: \(retryMilliseconds)\n"
        }

        let normalized = data
            .replacingOccurrences(
                of: "\r\n",
                with: "\n"
            )
            .replacingOccurrences(
                of: "\r",
                with: "\n"
            )

        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )

        for line in lines {
            output += "data: \(line)\n"
        }

        output += "\n"
        return output
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
        let payload = event.serialized()

        if flush {
            return writeStringAndFlush(payload)
        }

        return writeString(payload)
    }
}
