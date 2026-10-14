import NIOCore
import NIOHTTP1

public struct ProxyTrustPolicy: Sendable {
    public typealias Matcher = @Sendable (
        SocketAddress
    ) -> Bool

    private let matcher: Matcher

    public init(
        _ matcher: @escaping Matcher
    ) {
        self.matcher = matcher
    }

    @inline(__always)
    public func trusts(
        _ address: SocketAddress
    ) -> Bool {
        matcher(address)
    }
}

extension Context {
    public func clientIPAddress(
        for request: Request,
        trusting policy: ProxyTrustPolicy
    ) -> String? {
        ForwardedClientIPResolver.resolve(
            remoteAddress: remoteAddress,
            headers: request.headers,
            policy: policy
        )
    }

    public func clientIPAddress(
        for request: StreamRequest,
        trusting policy: ProxyTrustPolicy
    ) -> String? {
        ForwardedClientIPResolver.resolve(
            remoteAddress: remoteAddress,
            headers: request.headers,
            policy: policy
        )
    }
}

private enum ForwardedClientIPResolver {
    static func resolve(
        remoteAddress: SocketAddress?,
        headers: HTTPHeaders,
        policy: ProxyTrustPolicy
    ) -> String? {
        guard
            let remoteAddress,
            let remoteIP = remoteAddress.ipAddress
        else {
            return nil
        }

        guard policy.trusts(remoteAddress) else {
            return remoteIP
        }

        let forwarded = forwardedAddresses(
            headers
        )

        guard !forwarded.isEmpty else {
            return remoteIP
        }

        var currentAddress = remoteAddress
        var currentIP = remoteIP

        for value in forwarded.reversed() {
            guard policy.trusts(currentAddress) else {
                break
            }

            guard let candidate =
                parseAddress(value)
            else {
                break
            }

            currentAddress = candidate
            currentIP =
                candidate.ipAddress
                ?? currentIP
        }

        return currentIP
    }

    private static func forwardedAddresses(
        _ headers: HTTPHeaders
    ) -> [Substring] {
        var result: [Substring] = []

        for (name, value) in headers {
            guard isXForwardedFor(name) else {
                continue
            }

            var start = value.startIndex
            var cursor = start

            while true {
                if
                    cursor == value.endIndex
                    || value[cursor] == ","
                {
                    let token = value[
                        start..<cursor
                    ]
                    result.append(token)

                    guard cursor != value.endIndex else {
                        break
                    }

                    cursor = value.index(
                        after: cursor
                    )
                    start = cursor
                    continue
                }

                cursor = value.index(
                    after: cursor
                )
            }
        }

        return result
    }

    private static func parseAddress(
        _ raw: Substring
    ) -> SocketAddress? {
        let trimmed = trimOWS(raw)

        guard !trimmed.isEmpty else {
            return nil
        }

        let addressText: String

        if
            trimmed.first == "[",
            trimmed.last == "]",
            trimmed.count > 2
        {
            addressText = String(
                trimmed.dropFirst().dropLast()
            )
        } else {
            addressText = String(trimmed)
        }

        return try? SocketAddress(
            ipAddress: addressText,
            port: 0
        )
    }

    private static func trimOWS(
        _ value: Substring
    ) -> Substring {
        var lower = value.startIndex
        var upper = value.endIndex

        while lower != upper {
            let character = value[lower]

            guard
                character == " "
                || character == "\t"
            else {
                break
            }

            lower = value.index(
                after: lower
            )
        }

        while upper != lower {
            let previous = value.index(
                before: upper
            )
            let character = value[previous]

            guard
                character == " "
                || character == "\t"
            else {
                break
            }

            upper = previous
        }

        return value[lower..<upper]
    }

    @inline(__always)
    private static func isXForwardedFor(
        _ name: String
    ) -> Bool {
        let bytes = name.utf8
        let expected = "x-forwarded-for".utf8

        guard bytes.count == expected.count else {
            return false
        }

        var left = bytes.startIndex
        var right = expected.startIndex

        while left != bytes.endIndex {
            let byte = bytes[left]
            let folded =
                byte >= 65 && byte <= 90
                ? byte + 32
                : byte

            guard folded == expected[right] else {
                return false
            }

            bytes.formIndex(after: &left)
            expected.formIndex(after: &right)
        }

        return true
    }
}
