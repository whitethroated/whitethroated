import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import WhiteThroated
import WhiteThroatedAuth

public struct Session:
    Sendable,
    Codable,
    Equatable
{
    public let id: String
    public var values: [String: String]
    public let createdAtSeconds: UInt64
    public var lastAccessAtSeconds: UInt64

    public init(
        id: String,
        values: [String: String] = [:],
        createdAtSeconds: UInt64,
        lastAccessAtSeconds: UInt64
    ) {
        precondition(
            !id.isEmpty,
            "Session id must not be empty"
        )

        self.id = id
        self.values = values
        self.createdAtSeconds =
            createdAtSeconds
        self.lastAccessAtSeconds =
            lastAccessAtSeconds
    }
}

public protocol SessionStore:
    Sendable
{
    func load(
        id: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Session?>

    func save(
        _ session: Session,
        ttlSeconds: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void>

    func delete(
        id: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void>
}

public struct SessionClock:
    Sendable
{
    private let read:
        @Sendable () -> UInt64

    public init(
        nowSeconds:
            @escaping @Sendable () -> UInt64
    ) {
        self.read = nowSeconds
    }

    public func nowSeconds() -> UInt64 {
        read()
    }

    public static let wall =
        SessionClock {
            UInt64(
                max(
                    0,
                    Date()
                        .timeIntervalSince1970
                )
            )
        }
}

public final class MemorySessionStore:
    SessionStore,
    @unchecked Sendable
{
    private struct Stored:
        Sendable
    {
        var session: Session
        var expiresAt: UInt64
        var lastTouch: UInt64
    }

    private struct State:
        Sendable
    {
        var sessions:
            [String: Stored] = [:]
        var sequence: UInt64 = 0
    }

    public let maxSessions: Int

    private let clock: SessionClock
    private let state =
        NIOLockedValueBox(State())

    public init(
        maxSessions: Int = 10_000,
        clock: SessionClock = .wall
    ) {
        precondition(
            maxSessions > 0,
            "maxSessions must be greater than zero"
        )

        self.maxSessions = maxSessions
        self.clock = clock
    }

    public func load(
        id: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Session?> {
        let now = clock.nowSeconds()
        let value =
            state.withLockedValue {
                state -> Session? in

                guard var stored =
                    state.sessions[id]
                else {
                    return nil
                }

                guard
                    stored.expiresAt > now
                else {
                    state.sessions
                        .removeValue(
                            forKey: id
                        )
                    return nil
                }

                state.sequence &+= 1
                stored.lastTouch =
                    state.sequence
                stored.session
                    .lastAccessAtSeconds =
                    now
                state.sessions[id] =
                    stored

                return stored.session
            }

        return eventLoop
            .makeSucceededFuture(value)
    }

    public func save(
        _ session: Session,
        ttlSeconds: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        guard ttlSeconds > 0 else {
            return eventLoop
                .makeFailedFuture(
                    SessionStoreError
                        .invalidTTL
                )
        }

        let now = clock.nowSeconds()
        let ttl = UInt64(ttlSeconds)
        let expires =
            now > UInt64.max - ttl
            ? UInt64.max
            : now + ttl

        state.withLockedValue {
            state in

            state.sequence &+= 1

            if
                state.sessions[
                    session.id
                ] == nil,
                state.sessions.count
                    >= maxSessions
            {
                Self.evictOldest(
                    from:
                        &state.sessions
                )
            }

            state.sessions[
                session.id
            ] = Stored(
                session: session,
                expiresAt: expires,
                lastTouch:
                    state.sequence
            )
        }

        return eventLoop
            .makeSucceededVoidFuture()
    }

    public func delete(
        id: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        state.withLockedValue {
            state in
            _ = state.sessions
                .removeValue(
                    forKey: id
                )
        }

        return eventLoop
            .makeSucceededVoidFuture()
    }

    public var count: Int {
        state.withLockedValue {
            $0.sessions.count
        }
    }

    private static func evictOldest(
        from sessions:
            inout [String: Stored]
    ) {
        guard
            let key =
                sessions.min(
                    by: {
                        $0.value
                            .lastTouch
                            < $1.value
                                .lastTouch
                    }
                )?.key
        else {
            return
        }

        sessions.removeValue(
            forKey: key
        )
    }
}

public enum SessionStoreError:
    Error,
    Sendable
{
    case invalidTTL
}

public struct SessionSigningKey:
    Sendable
{
    public let id: String
    internal let key: SymmetricKey

    public init(
        id: String,
        secret: [UInt8]
    ) {
        precondition(
            !id.isEmpty,
            "Session signing key id must not be empty"
        )
        precondition(
            secret.count >= 32,
            "Session signing secret must be at least 32 bytes"
        )

        self.id = id
        self.key = SymmetricKey(
            data: Data(secret)
        )
    }
}

public struct SessionCookieCodec:
    Sendable
{
    public let keys:
        [SessionSigningKey]

    public init(
        keys: [SessionSigningKey]
    ) {
        precondition(
            !keys.isEmpty,
            "At least one session signing key is required"
        )

        let ids = Set(
            keys.map(\.id)
        )
        precondition(
            ids.count == keys.count,
            "Session signing key ids must be unique"
        )

        self.keys = keys
    }

    public func encode(
        sessionID: String
    ) -> String {
        let key = keys[0]
        let message =
            key.id + "." + sessionID
        let signature =
            HMAC<SHA256>
                .authenticationCode(
                    for:
                        Data(message.utf8),
                    using: key.key
                )

        return message
            + "."
            + Self.hex(
                Array(signature)
            )
    }

    public func decode(
        _ value: String
    ) -> String? {
        let pieces =
            value.split(
                separator: ".",
                omittingEmptySubsequences:
                    false
            )

        guard pieces.count == 3 else {
            return nil
        }

        let keyID =
            String(pieces[0])
        let sessionID =
            String(pieces[1])
        let supplied =
            String(pieces[2])

        guard
            !sessionID.isEmpty,
            let key =
                keys.first(
                    where: {
                        $0.id == keyID
                    }
                ),
            supplied.utf8.count == 64
        else {
            return nil
        }

        let message =
            keyID + "." + sessionID
        let expectedCode =
            HMAC<SHA256>
                .authenticationCode(
                    for:
                        Data(
                            message.utf8
                        ),
                    using: key.key
                )
        let expected =
            Self.hex(
                Array(expectedCode)
            )

        guard
            Self.constantTimeEqual(
                expected,
                supplied.lowercased()
            )
        else {
            return nil
        }

        return sessionID
    }

    private static func hex<C>(
        _ bytes: C
    ) -> String
    where
        C: Collection,
        C.Element == UInt8
    {
        let table =
            Array(
                "0123456789abcdef".utf8
            )
        var output = [UInt8]()
        output.reserveCapacity(
            bytes.count * 2
        )

        for byte in bytes {
            output.append(
                table[
                    Int(byte >> 4)
                ]
            )
            output.append(
                table[
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
}

public struct SessionCookieConfiguration:
    Sendable
{
    public let name: String
    public let path: String
    public let secure: Bool
    public let sameSite:
        CookieOptions.SameSite

    public init(
        name: String = "wt_session",
        path: String = "/",
        secure: Bool = true,
        sameSite:
            CookieOptions.SameSite = .lax
    ) {
        precondition(
            !name.isEmpty,
            "Session cookie name must not be empty"
        )
        precondition(
            !path.isEmpty,
            "Session cookie path must not be empty"
        )

        self.name = name
        self.path = path
        self.secure = secure
        self.sameSite = sameSite
    }

    public var options:
        CookieOptions
    {
        CookieOptions(
            path: path,
            httpOnly: true,
            secure: secure,
            sameSite: sameSite
        )
    }
}

public struct SessionManager:
    Sendable
{
    public typealias IDGenerator =
        @Sendable () -> String

    public let store:
        any SessionStore
    public let codec:
        SessionCookieCodec
    public let cookie:
        SessionCookieConfiguration
    public let ttlSeconds: Int

    private let clock:
        SessionClock
    private let idGenerator:
        IDGenerator

    public init(
        store: any SessionStore,
        codec: SessionCookieCodec,
        cookie:
            SessionCookieConfiguration =
                SessionCookieConfiguration(),
        ttlSeconds: Int = 86_400,
        clock: SessionClock = .wall,
        idGenerator:
            @escaping IDGenerator = {
                UUID().uuidString
            }
    ) {
        precondition(
            ttlSeconds > 0,
            "Session ttlSeconds must be greater than zero"
        )

        self.store = store
        self.codec = codec
        self.cookie = cookie
        self.ttlSeconds = ttlSeconds
        self.clock = clock
        self.idGenerator = idGenerator
    }

    public func load(
        from request: Request,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Session?> {
        guard
            let value =
                request.cookie(
                    cookie.name
                ),
            let id =
                codec.decode(value)
        else {
            return eventLoop
                .makeSucceededFuture(nil)
        }

        return store.load(
            id: id,
            on: eventLoop
        )
    }

    public func create()
        -> Session
    {
        let now = clock.nowSeconds()

        return Session(
            id: idGenerator(),
            createdAtSeconds: now,
            lastAccessAtSeconds: now
        )
    }

    public func persist(
        _ session: Session,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<String> {
        let updated =
            Session(
                id: session.id,
                values: session.values,
                createdAtSeconds:
                    session.createdAtSeconds,
                lastAccessAtSeconds:
                    clock.nowSeconds()
            )

        return store.save(
            updated,
            ttlSeconds: ttlSeconds,
            on: eventLoop
        )
        .map {
            codec.encode(
                sessionID:
                    updated.id
            )
        }
    }

    public func rotate(
        _ session: Session,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Session> {
        let now = clock.nowSeconds()
        let rotated =
            Session(
                id: idGenerator(),
                values:
                    session.values,
                createdAtSeconds: now,
                lastAccessAtSeconds:
                    now
            )

        return store.delete(
            id: session.id,
            on: eventLoop
        )
        .flatMap {
            self.store.save(
                rotated,
                ttlSeconds:
                    self.ttlSeconds,
                on: eventLoop
            )
        }
        .map {
            rotated
        }
    }

    public func destroy(
        _ session: Session,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        store.delete(
            id: session.id,
            on: eventLoop
        )
    }

    public func setCookie(
        value: String,
        on response:
            inout Response
    ) {
        response.setCookie(
            cookie.name,
            value: value,
            options:
                cookie.options
        )
    }

    public func clearCookie(
        on response:
            inout Response
    ) {
        // Deletion parity: the clearing cookie repeats the exact
        // attributes of the session cookie (path, HttpOnly, Secure,
        // SameSite) with an empty value and Max-Age=0, so the
        // browser matches and expires the original instead of
        // storing a second attribute set.
        var deletionOptions =
            cookie.options
        deletionOptions.maxAgeSeconds = 0

        response.setCookie(
            cookie.name,
            value: "",
            options: deletionOptions
        )
    }
}


public extension SessionManager {
    func authenticator(
        principal:
            @escaping @Sendable (
                Session
            ) -> AuthPrincipal?
    ) -> EventLoopAuthenticator {
        EventLoopAuthenticator {
            request,
            context in

            self.load(
                from: request,
                on: context.eventLoop
            )
            .map {
                session in

                guard let session else {
                    return nil
                }

                return principal(session)
            }
        }
    }
}
