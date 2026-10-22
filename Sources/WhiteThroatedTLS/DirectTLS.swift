import NIOCore
import NIOSSL
import WhiteThroated

public enum DirectTLSMinimumVersion:
    Sendable
{
    case tls12
    case tls13

    fileprivate var nioVersion:
        TLSVersion
    {
        switch self {
        case .tls12:
            return .tlsv12
        case .tls13:
            return .tlsv13
        }
    }
}

/// Setup-time direct TLS configuration for WhiteThroated.
///
/// The expensive `NIOSSLContext` is created before the server starts.
/// Accepted connections only allocate one `NIOSSLServerHandler` before
/// the HTTP pipeline is installed.
public struct DirectTLS: Sendable {
    public let context: NIOSSLContext

    public init(
        certificateChain:
            [NIOSSLCertificate],
        privateKey:
            NIOSSLPrivateKey,
        minimumVersion:
            DirectTLSMinimumVersion = .tls12,
        applicationProtocols:
            [String] = ["http/1.1"]
    ) throws {
        precondition(
            !certificateChain.isEmpty,
            "TLS certificate chain must not be empty"
        )

        Self.validateApplicationProtocols(
            applicationProtocols
        )

        var configuration =
            TLSConfiguration
                .makeServerConfiguration(
                    certificateChain:
                        certificateChain.map {
                            .certificate($0)
                        },
                    privateKey:
                        .privateKey(privateKey)
                )

        configuration.minimumTLSVersion =
            minimumVersion.nioVersion
        configuration.maximumTLSVersion = nil
        configuration.applicationProtocols =
            applicationProtocols
        configuration.renegotiationSupport =
            .none

        self.context = try NIOSSLContext(
            configuration: configuration
        )
    }

    /// Loads a PEM certificate chain and private key during setup.
    /// File I/O must not be performed from an event-loop callback.
    public init(
        certificateChainPEMFile:
            String,
        privateKeyPEMFile:
            String,
        minimumVersion:
            DirectTLSMinimumVersion = .tls12,
        applicationProtocols:
            [String] = ["http/1.1"]
    ) throws {
        let certificates =
            try NIOSSLCertificate
                .fromPEMFile(
                    certificateChainPEMFile
                )
        let privateKey =
            try NIOSSLPrivateKey(
                file: privateKeyPEMFile,
                format: .pem
            )

        try self.init(
            certificateChain:
                certificates,
            privateKey:
                privateKey,
            minimumVersion:
                minimumVersion,
            applicationProtocols:
                applicationProtocols
        )
    }

    /// Builds TLS entirely from already-loaded PEM bytes.
    public init(
        certificateChainPEMBytes:
            [UInt8],
        privateKeyPEMBytes:
            [UInt8],
        minimumVersion:
            DirectTLSMinimumVersion = .tls12,
        applicationProtocols:
            [String] = ["http/1.1"]
    ) throws {
        let certificates =
            try NIOSSLCertificate
                .fromPEMBytes(
                    certificateChainPEMBytes
                )
        let privateKey =
            try NIOSSLPrivateKey(
                bytes:
                    privateKeyPEMBytes,
                format: .pem
            )

        try self.init(
            certificateChain:
                certificates,
            privateKey:
                privateKey,
            minimumVersion:
                minimumVersion,
            applicationProtocols:
                applicationProtocols
        )
    }

    public func install(
        on application: Application
    ) {
        application
            .installAcceptedChannelInitializer {
                channel in

                self.configure(channel)
            }
    }

    internal func configure(
        _ channel: Channel
    ) -> EventLoopFuture<Void> {
        channel.pipeline.addHandler(
            NIOSSLServerHandler(
                context: context
            ),
            position: .first
        )
    }

    private static func validateApplicationProtocols(
        _ protocols: [String]
    ) {
        for value in protocols {
            precondition(
                !value.isEmpty,
                "TLS ALPN identifiers must not be empty"
            )
            precondition(
                value.utf8.count <= 255,
                "TLS ALPN identifiers must fit in one byte of length"
            )
            precondition(
                value.unicodeScalars.allSatisfy {
                    $0.isASCII
                },
                "TLS ALPN identifiers must be ASCII"
            )
        }
    }
}

public extension Application {
    func use(directTLS: DirectTLS) {
        directTLS.install(on: self)
    }
}
