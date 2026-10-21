import Foundation
import NIOCore
import RediStack
import WhiteThroatedSessions

public final class RedisSessionStore:
    SessionStore,
    @unchecked Sendable
{
    public let client: any RedisClient
    public let keyPrefix: String

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        self.encoder = encoder
        self.decoder = decoder
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

                return try decoder.decode(
                    Session.self,
                    from:
                        Data(encoded.utf8)
                )
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
                try encoder.encode(
                    session
                )
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
