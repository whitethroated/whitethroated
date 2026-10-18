import NIOCore
import NIOEmbedded
import XCTest
@testable import BenchmarkHTTP1Experiment

final class BenchmarkHTTP1ExperimentTests: XCTestCase {
    func testMatchedBenchmarkRoutesEmitExpectedWireBytes() throws {
        let fixture = try Fixture()

        try fixture.write(
            "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        )

        try fixture.write(
            "GET /prepared HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 13\r\ndate: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\nHello, World!"
        )

        try fixture.write(
            "GET /json HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: 27\r\n\r\n{\"message\":\"Hello, World!\"}"
        )

        try fixture.write(
            "GET /user/42 HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 2\r\n\r\n42"
        )

        try fixture.write(
            "POST /user HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        )
    }

    func testFragmentedRequestWaitsForCompleteHead() throws {
        let fixture = try Fixture()

        try fixture.write(
            "GET /json HTTP/1.1\r\nho"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            ""
        )

        try fixture.write(
            "st: localhost\r\n\r\n"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: 27\r\n\r\n{\"message\":\"Hello, World!\"}"
        )
    }

    func testContentLengthBodyIsConsumedBeforeDispatch() throws {
        let fixture = try Fixture()

        try fixture.write(
            "POST /user HTTP/1.1\r\nhost: localhost\r\ncontent-length: 3\r\n\r\na"
        )
        XCTAssertEqual(
            try fixture.readAll(),
            ""
        )

        try fixture.write("bc")
        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        )
    }

    func testMultipleRequestsInOneReadAreConsumedInOrder() throws {
        let fixture = try Fixture()

        try fixture.write(
            "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n"
            + "GET /user/7 HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )

        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
            + "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 1\r\n\r\n7"
        )
    }

    func testHeadSuppressesResponseBody() throws {
        let fixture = try Fixture()

        try fixture.write(
            "HEAD /json HTTP/1.1\r\nhost: localhost\r\n\r\n"
        )

        XCTAssertEqual(
            try fixture.readAll(),
            "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: 27\r\n\r\n"
        )
    }

    func testAmbiguousOrUnsupportedFramingIsRejected() throws {
        for request in [
            "POST /user HTTP/1.1\r\nhost: localhost\r\ncontent-length: 0\r\ncontent-length: 0\r\n\r\n",
            "POST /user HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\ncontent-length: 0\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n"
        ] {
            let fixture = try Fixture()
            try fixture.write(request)

            XCTAssertEqual(
                try fixture.readAll(),
                "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )
            fixture.loop.run()
            XCTAssertFalse(fixture.channel.isActive)
        }
    }
}

private final class Fixture {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel

    init() throws {
        channel = EmbeddedChannel(loop: loop)

        try channel.pipeline.syncOperations.addHandler(
            CustomHTTP1BenchmarkHandler(
                allocator: channel.allocator
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()
    }

    deinit {
        _ = try? channel.finish()
    }

    func write(_ string: String) throws {
        var buffer = channel.allocator.buffer(
            capacity: string.utf8.count
        )
        buffer.writeString(string)

        try channel.writeInbound(buffer)
        loop.run()
    }

    func readAll() throws -> String {
        loop.run()

        var result = ""

        while var buffer = try channel.readOutbound(
            as: ByteBuffer.self
        ) {
            result += buffer.readString(
                length: buffer.readableBytes
            ) ?? ""
        }

        return result
    }
}
