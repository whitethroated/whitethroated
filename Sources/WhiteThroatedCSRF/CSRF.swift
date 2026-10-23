import Crypto
import Foundation
import NIOHTTP1
import WhiteThroated
import WhiteThroatedSessions

public enum CSRFOriginPolicy:
    Sendable
{
    case disabled
    case allowed(
        Set<String>,
        requireOriginOrReferer: Bool
    )
}

public struct CSRFProtection:
    Sendable
{
    public let headerName: String
    public let sessionKey: String
    public let originPolicy:
        CSRFOriginPolicy

    private let failureResponseProvider:
        @Sendable () -> Response

    public init(
        headerName: String =
            "x-csrf-token",
        sessionKey: String =
            "_csrf",
        originPolicy:
            CSRFOriginPolicy =
                .disabled,
        failureResponse:
            @escaping @Sendable () -> Response =
                {
                    .text(
                        "CSRF validation failed",
                        status: .forbidden
                    )
                }
    ) {
        precondition(
            !headerName.isEmpty,
            "CSRF header name must not be empty"
        )
        precondition(
            !sessionKey.isEmpty,
            "CSRF session key must not be empty"
        )

        self.headerName = headerName
        self.sessionKey = sessionKey
        self.originPolicy =
            originPolicy
        self.failureResponseProvider =
            failureResponse
    }

    public func ensureToken(
        in session:
            inout Session
    ) -> String {
        if
            let existing =
                session.values[
                    sessionKey
                ],
            !existing.isEmpty
        {
            return existing
        }

        let key =
            SymmetricKey(
                size: .bits256
            )
        let token =
            key.withUnsafeBytes {
                bytes in
                Self.hex(bytes)
            }

        session.values[
            sessionKey
        ] = token

        return token
    }

    public func validate(
        request: Request,
        session: Session
    ) -> Bool {
        if Self.isSafe(
            request.method
        ) {
            return true
        }

        guard
            validateOrigin(request),
            let expected =
                session.values[
                    sessionKey
                ],
            let supplied =
                request.header(
                    headerName
                ),
            Self.constantTimeEqual(
                expected,
                supplied
            )
        else {
            return false
        }

        return true
    }

    /// The response returned when `validate(request:session:)`
    /// fails. The default is a 403 text response; applications
    /// customize it through the `failureResponse` initializer
    /// parameter, for example to answer with the JSON error body
    /// their API convention uses.
    public func failureResponse()
        -> Response
    {
        failureResponseProvider()
    }

    private func validateOrigin(
        _ request: Request
    ) -> Bool {
        switch originPolicy {
        case .disabled:
            return true

        case .allowed(
            let allowed,
            let require
        ):
            if
                let origin =
                    request.header(
                        "origin"
                    )
            {
                return allowed
                    .contains(origin)
            }

            if
                let referer =
                    request.header(
                        "referer"
                    ),
                let url =
                    URL(
                        string: referer
                    ),
                let scheme =
                    url.scheme,
                let host =
                    url.host
            {
                var origin =
                    scheme
                    + "://"
                    + host

                if let port = url.port {
                    origin +=
                        ":" + String(port)
                }

                return allowed
                    .contains(origin)
            }

            return !require
        }
    }

    private static func isSafe(
        _ method:
            WhiteThroated.HTTPMethod
    ) -> Bool {
        switch method {
        case .get,
             .head,
             .options,
             .trace:
            return true

        default:
            return false
        }
    }

    private static func constantTimeEqual(
        _ left: String,
        _ right: String
    ) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)

        guard a.count == b.count else {
            return false
        }

        var difference: UInt8 = 0

        for index in a.indices {
            difference |=
                a[index] ^ b[index]
        }

        return difference == 0
    }

    private static func hex<C>(
        _ bytes: C
    ) -> String
    where
        C: Collection,
        C.Element == UInt8
    {
        let digits =
            Array(
                "0123456789abcdef".utf8
            )
        var output = [UInt8]()
        output.reserveCapacity(
            bytes.count * 2
        )

        for byte in bytes {
            output.append(
                digits[
                    Int(byte >> 4)
                ]
            )
            output.append(
                digits[
                    Int(
                        byte & 0x0f
                    )
                ]
            )
        }

        return String(
            decoding: output,
            as: UTF8.self
        )
    }
}
