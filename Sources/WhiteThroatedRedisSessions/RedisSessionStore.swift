import Foundation
import NIOConcurrencyHelpers
import NIOCore
import RediStack
import WhiteThroatedSessions

public final class RedisSessionStore:
    SessionStore,
    @unchecked Sendable
{
    // JSONEncoder and JSONDecoder are reference types with mutable state.
    // `codecs` serializes every access, so sharing them across event loops is
    // safe; the unchecked conformance is justified by that single lock.
    private struct Codecs:
        @unchecked Sendable
    {
        let encoder: JSONEncoder
        let decoder: JSONDecoder
    }

    public let client: any RedisClient
    public let keyPrefix: String

    private let codecs: NIOLockedValueBox<Codecs>

    public init(
        client: any RedisClient,
        keyPrefix: String =
            "whitethroated:session:",
        encoder: JSONEncoder =
            JSONEncoder(),
        decoder: JSONDecoder =
            JSONDecoder()
    ) {
        precondition(
            !keyPrefix.isEmpty,
            "Redis session key prefix must not be empty"
        )

        self.client = client
        self.keyPrefix = keyPrefix
        self.codecs =
            NIOLockedValueBox(
                Codecs(
                    encoder: encoder,
                    decoder: decoder
                )
            )
    }

    public func load(
        id: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Session?> {
        let key = RedisKey(
            keyPrefix + id
        )

        return client
            .get(
                key,
                as: String.self
            )
            .hop(to: eventLoop)
            .flatMapThrowing {
                encoded in

                guard let encoded else {
                    return nil
                }

                return try self.codecs
                    .withLockedValue {
                        try $0.decoder.decode(
                            Session.self,
                            from:
                                Data(
                                    encoded.utf8
                                )
                        )
                    }
            }
    }

    public func save(
        _ session: Session,
        ttlSeconds: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        guard ttlSeconds > 0 else {
            return eventLoop
                .makeFailedFuture(
                    RedisSessionStoreError
                        .invalidTTL
                )
        }

        do {
            let data =
                try codecs
                    .withLockedValue {
                        try $0.encoder.encode(
                            session
                        )
                    }
            let encoded =
                String(
                    decoding: data,
                    as: UTF8.self
                )

            return client
                .setex(
                    RedisKey(
                        keyPrefix
                            + session.id
                    ),
                    to: encoded,
                    expirationInSeconds:
                        ttlSeconds
                )
                .hop(to: eventLoop)
        } catch {
            return eventLoop
                .makeFailedFuture(error)
        }
    }

    public func delete(
        id: String,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        client
            .delete(
                RedisKey(
                    keyPrefix + id
                )
            )
            .hop(to: eventLoop)
            .map { _ in () }
    }
}

public enum RedisSessionStoreError:
    Error,
    Sendable
{
    case invalidTTL
}
