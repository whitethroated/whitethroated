import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ProxyTrustPolicyTests: XCTestCase {
    func testUntrustedPeerIgnoresForwardedHeader() throws {
        let remote = try address(
            "203.0.113.10"
        )
        let request = makeRequest(
            forwardedFor: "198.51.100.20"
        )
        let context = Context(
            eventLoop: EmbeddedEventLoop(),
            remoteAddress: remote
        )
        let trust = ProxyTrustPolicy { _ in
            false
        }

        XCTAssertEqual(
            context.clientIPAddress(
                for: request,
                trusting: trust
            ),
            "203.0.113.10"
        )
    }

    func testTrustedPeerUsesForwardedClientAddress() throws {
        let remote = try address(
            "10.0.0.3"
        )
        let request = makeRequest(
            forwardedFor: "198.51.100.20"
        )
        let context = Context(
            eventLoop: EmbeddedEventLoop(),
            remoteAddress: remote
        )
        let trust = ProxyTrustPolicy { address in
            address.ipAddress == "10.0.0.3"
        }

        XCTAssertEqual(
            context.clientIPAddress(
                for: request,
                trusting: trust
            ),
            "198.51.100.20"
        )
    }

    func testResolverWalksTrustedProxyChainRightToLeft()
        throws
    {
        let remote = try address(
            "10.0.0.3"
        )
        let request = makeRequest(
            forwardedFor:
                "198.51.100.20, 10.0.0.2"
        )
        let context = Context(
            eventLoop: EmbeddedEventLoop(),
            remoteAddress: remote
        )
        let trust = ProxyTrustPolicy { address in
            switch address.ipAddress {
            case "10.0.0.2", "10.0.0.3":
                return true
            default:
                return false
            }
        }

        XCTAssertEqual(
            context.clientIPAddress(
                for: request,
                trusting: trust
            ),
            "198.51.100.20"
        )
    }

    func testResolverStopsAtFirstUntrustedProxy()
        throws
    {
        let remote = try address(
            "10.0.0.3"
        )
        let request = makeRequest(
            forwardedFor:
                "198.51.100.20, 10.0.0.2"
        )
        let context = Context(
            eventLoop: EmbeddedEventLoop(),
            remoteAddress: remote
        )
        let trust = ProxyTrustPolicy { address in
            address.ipAddress == "10.0.0.3"
        }

        XCTAssertEqual(
            context.clientIPAddress(
                for: request,
                trusting: trust
            ),
            "10.0.0.2"
        )
    }

    func testMalformedForwardedEntryDoesNotJumpPastTrustBoundary()
        throws
    {
        let remote = try address(
            "10.0.0.3"
        )
        let request = makeRequest(
            forwardedFor:
                "198.51.100.20, not-an-ip"
        )
        let context = Context(
            eventLoop: EmbeddedEventLoop(),
            remoteAddress: remote
        )
        let trust = ProxyTrustPolicy { address in
            address.ipAddress == "10.0.0.3"
        }

        XCTAssertEqual(
            context.clientIPAddress(
                for: request,
                trusting: trust
            ),
            "10.0.0.3"
        )
    }

    func testBracketedIPv6ForwardedAddressIsAccepted()
        throws
    {
        let remote = try address(
            "10.0.0.3"
        )
        let request = makeRequest(
            forwardedFor: "[2001:db8::1]"
        )
        let context = Context(
            eventLoop: EmbeddedEventLoop(),
            remoteAddress: remote
        )
        let trust = ProxyTrustPolicy { address in
            address.ipAddress == "10.0.0.3"
        }

        XCTAssertEqual(
            context.clientIPAddress(
                for: request,
                trusting: trust
            ),
            "2001:db8::1"
        )
    }

    private func address(
        _ ip: String
    ) throws -> SocketAddress {
        try SocketAddress(
            ipAddress: ip,
            port: 8080
        )
    }

    private func makeRequest(
        forwardedFor: String
    ) -> Request {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )
        head.headers.add(
            name: "x-forwarded-for",
            value: forwardedFor
        )

        return Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )
    }
}
