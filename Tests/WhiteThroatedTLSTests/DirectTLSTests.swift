import NIOEmbedded
import NIOSSL
import XCTest
@testable import WhiteThroatedTLS

final class DirectTLSTests: XCTestCase {
    func testDefaultsToTLS12AndHTTP11() throws {
        let tls = try makeTLS()

        switch tls.context
            .configuration
            .minimumTLSVersion
        {
        case .tlsv12:
            break
        default:
            XCTFail(
                "Direct TLS must default to TLS 1.2 or newer"
            )
        }

        XCTAssertEqual(
            tls.context
                .configuration
                .applicationProtocols,
            ["http/1.1"]
        )
    }

    func testInstallsServerTLSHandlerBeforeHTTPSetup() throws {
        let tls = try makeTLS()
        let channel = EmbeddedChannel()

        try tls.configure(channel).wait()

        XCTAssertNoThrow(
            try channel.pipeline
                .syncOperations
                .handler(
                    type:
                        NIOSSLServerHandler.self
                )
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    private func makeTLS() throws
        -> DirectTLS
    {
        try DirectTLS(
            certificateChainPEMBytes:
                Array(
                    Self.certificatePEM.utf8
                ),
            privateKeyPEMBytes:
                Array(
                    Self.privateKeyPEM.utf8
                )
        )
    }

    private static let certificatePEM =
        """
        -----BEGIN CERTIFICATE-----
        MIIBTzCB9qADAgECAhQkvv72Je/v+B/cgJ53f84O82z6WTAKBggqhkjOPQQDAjAU
        MRIwEAYDVQQDDAlsb2NhbGhvc3QwHhcNMTkxMTI3MTAxMjMwWhcNMjkxMTI0MTAx
        MjMwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMB
        BwNCAAShtZ9TRt7I+7Y0o99XUkrgSYmUmpr4K8CB0IkTCX6b1tXp3Xqs1V5BckTd
        qrls+zsm3AfeiNBb9EDdxiX9DdzuoyYwJDAUBgNVHREEDTALgglsb2NhbGhvc3Qw
        DAYDVR0TAQH/BAIwADAKBggqhkjOPQQDAgNIADBFAiAKxYON+YTnIHNR0R6SLP8R
        R7hjsjV5NDs18XLoeRnA1gIhANwyggmE6NQW/r9l59fexj/ZrjaS3jYOTNCfC1Lo
        5NgJ
        -----END CERTIFICATE-----
        """

    private static let privateKeyPEM =
        """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgCn182hBmYVMAiNPO
        +7w05F40SlAqqxgBEYJZOeK47aihRANCAAShtZ9TRt7I+7Y0o99XUkrgSYmUmpr4
        K8CB0IkTCX6b1tXp3Xqs1V5BckTdqrls+zsm3AfeiNBb9EDdxiX9Ddzu
        -----END PRIVATE KEY-----
        """
}
