import Crypto
import Foundation
import WhiteThroated
import WhiteThroatedAuth
import WhiteThroatedRateLimit

public struct AuthRateLimitKeyDeriver:
    Sendable
{
    private let key:
        SymmetricKey

    public init(
        secret: [UInt8]
    ) {
        precondition(
            secret.count >= 32,
            "Auth rate-limit secret must be at least 32 bytes"
        )

        self.key =
            SymmetricKey(
                data: Data(secret)
            )
    }

    public func key(
        for principal:
            AuthPrincipal
    ) -> String {
        let code =
            HMAC<SHA256>
                .authenticationCode(
                    for:
                        Data(
                            principal
                                .id
                                .utf8
                        ),
                    using: key
                )

        return Self.hex(code)
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

public enum AuthRateLimit {
    public static func fixedWindow(
        authenticator:
            Authenticator,
        keyDeriver:
            AuthRateLimitKeyDeriver,
        configuration:
            FixedWindowRateLimitConfiguration,
        clock: RateLimitClock =
            .monotonic
    ) -> FixedWindowRateLimiter {
        FixedWindowRateLimiter(
            configuration:
                configuration,
            clock: clock,
            keyResolver: {
                request in

                guard
                    let principal =
                        authenticator
                            .authenticate(
                                request
                            )
                else {
                    return nil
                }

                return keyDeriver.key(
                    for: principal
                )
            }
        )
    }
}
