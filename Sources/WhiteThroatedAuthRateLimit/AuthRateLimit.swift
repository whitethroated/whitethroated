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

        return Self.hex(
            Array(code)
        )
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
    /// Binds a fixed-window rate limit to authenticated principals.
    ///
    /// The limiter keys requests on the HMAC of the authenticated
    /// principal id. A request that fails or omits authentication belongs
    /// to the authenticator stack rather than this limiter, so the
    /// wrapper's key-failure behavior defaults to `.passThrough` — the
    /// authenticator answers unauthenticated traffic itself instead of
    /// receiving a limiter 429. Fail-closed deployments opt into
    /// `.reject` explicitly. This value overrides the passed
    /// configuration's key failure behavior.
    public static func fixedWindow(
        authenticator:
            Authenticator,
        keyDeriver:
            AuthRateLimitKeyDeriver,
        configuration:
            FixedWindowRateLimitConfiguration,
        keyFailureBehavior:
            RateLimitKeyFailureBehavior =
                .passThrough,
        clock: RateLimitClock =
            .monotonic
    ) -> FixedWindowRateLimiter {
        let effectiveConfiguration =
            FixedWindowRateLimitConfiguration(
                limit: configuration.limit,
                windowSeconds: Int(
                    configuration
                        .windowNanoseconds
                    / 1_000_000_000
                ),
                maxKeys: configuration.maxKeys,
                maxKeyBytes:
                    configuration.maxKeyBytes,
                keyFailureBehavior:
                    keyFailureBehavior,
                emitHeaders:
                    configuration.emitHeaders
            )

        return FixedWindowRateLimiter(
            configuration:
                effectiveConfiguration,
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
