import Dispatch
import NIOConcurrencyHelpers
import WhiteThroated

public typealias RateLimitKeyResolver =
    @Sendable (Request) -> String?

public enum RateLimitKeyFailureBehavior: Sendable {
    case reject
    case passThrough
}

public struct FixedWindowRateLimitConfiguration: Sendable {
    public let limit: Int
    public let windowNanoseconds: UInt64
    public let maxKeys: Int
    public let maxKeyBytes: Int
    public let keyFailureBehavior:
        RateLimitKeyFailureBehavior
    public let emitHeaders: Bool

    public init(
        limit: Int,
        windowSeconds: Int,
        maxKeys: Int = 10_000,
        maxKeyBytes: Int = 256,
        keyFailureBehavior:
            RateLimitKeyFailureBehavior = .reject,
        emitHeaders: Bool = true
    ) {
        precondition(
            limit > 0,
            "Rate limit must be greater than zero"
        )
        precondition(
            windowSeconds > 0,
            "Rate limit windowSeconds must be greater than zero"
        )
        precondition(
            maxKeys > 0,
            "Rate limit maxKeys must be greater than zero"
        )
        precondition(
            maxKeyBytes > 0,
            "Rate limit maxKeyBytes must be greater than zero"
        )

        let seconds = UInt64(windowSeconds)

        precondition(
            seconds
                <= UInt64.max
                    / 1_000_000_000,
            "Rate limit windowSeconds is too large"
        )

        self.limit = limit
        self.windowNanoseconds =
            seconds * 1_000_000_000
        self.maxKeys = maxKeys
        self.maxKeyBytes = maxKeyBytes
        self.keyFailureBehavior =
            keyFailureBehavior
        self.emitHeaders = emitHeaders
    }
}

public struct RateLimitClock: Sendable {
    private let read:
        @Sendable () -> UInt64

    public init(
        nowNanoseconds:
            @escaping @Sendable () -> UInt64
    ) {
        self.read = nowNanoseconds
    }

    @inline(__always)
    func nowNanoseconds() -> UInt64 {
        read()
    }

    public static let monotonic =
        RateLimitClock {
            DispatchTime.now()
                .uptimeNanoseconds
        }
}

public struct RateLimitDecision: Sendable, Equatable {
    public let allowed: Bool
    public let limit: Int
    public let remaining: Int
    public let resetAfterSeconds: Int
    public let retryAfterSeconds: Int?

    public init(
        allowed: Bool,
        limit: Int,
        remaining: Int,
        resetAfterSeconds: Int,
        retryAfterSeconds: Int?
    ) {
        self.allowed = allowed
        self.limit = limit
        self.remaining = remaining
        self.resetAfterSeconds =
            resetAfterSeconds
        self.retryAfterSeconds =
            retryAfterSeconds
    }
}

public final class FixedWindowRateLimiter:
    @unchecked Sendable
{
    private struct Bucket: Sendable {
        var windowStart: UInt64
        var count: Int
        var lastTouch: UInt64
    }

    private struct State: Sendable {
        var buckets: [String: Bucket] = [:]
        var sequence: UInt64 = 0
    }

    public let configuration:
        FixedWindowRateLimitConfiguration

    private let keyResolver:
        RateLimitKeyResolver
    private let clock: RateLimitClock
    private let state =
        NIOLockedValueBox(State())

    public init(
        configuration:
            FixedWindowRateLimitConfiguration,
        clock: RateLimitClock = .monotonic,
        keyResolver:
            @escaping RateLimitKeyResolver
    ) {
        self.configuration = configuration
        self.clock = clock
        self.keyResolver = keyResolver
    }

    public func middleware() -> FastMiddleware {
        { request, _, next in
            self.respond(
                to: request,
                next: next
            )
        }
    }

    public func decision(
        for request: Request
    ) -> RateLimitDecision? {
        guard
            let key = normalizedKey(
                for: request
            )
        else {
            return nil
        }

        let now = clock.nowNanoseconds()

        return state.withLockedValue {
            state in

            state.sequence &+= 1
            let touch = state.sequence

            if var bucket =
                state.buckets[key]
            {
                let elapsed =
                    now >= bucket.windowStart
                    ? now - bucket.windowStart
                    : 0

                if elapsed
                    >= configuration
                        .windowNanoseconds
                {
                    bucket.windowStart = now
                    bucket.count = 1
                    bucket.lastTouch = touch
                    state.buckets[key] = bucket

                    return makeDecision(
                        allowed: true,
                        count: 1,
                        elapsedNanoseconds: 0
                    )
                }

                bucket.lastTouch = touch

                if bucket.count
                    < configuration.limit
                {
                    bucket.count += 1
                    state.buckets[key] = bucket

                    return makeDecision(
                        allowed: true,
                        count: bucket.count,
                        elapsedNanoseconds:
                            elapsed
                    )
                }

                state.buckets[key] = bucket

                return makeDecision(
                    allowed: false,
                    count: bucket.count,
                    elapsedNanoseconds:
                        elapsed
                )
            }

            if state.buckets.count
                >= configuration.maxKeys
            {
                Self.pruneOldest(
                    buckets: &state.buckets,
                    count: Self.evictionBatch(
                        configuration.maxKeys
                    )
                )
            }

            state.buckets[key] = Bucket(
                windowStart: now,
                count: 1,
                lastTouch: touch
            )

            return makeDecision(
                allowed: true,
                count: 1,
                elapsedNanoseconds: 0
            )
        }
    }

    func respond(
        to request: Request,
        next: @escaping FastNext
    ) -> MiddlewareResult {
        guard
            let decision = decision(
                for: request
            )
        else {
            return keyFailureResult(
                request: request,
                next: next
            )
        }

        guard decision.allowed else {
            return .response(
                limitedResponse(
                    decision
                )
            )
        }

        let result = next(request)

        guard configuration.emitHeaders else {
            return result
        }

        return result.map { response in
            var response = response
            self.applyLimitHeaders(
                decision,
                to: &response
            )
            return response
        }
    }

    var storedKeyCount: Int {
        state.withLockedValue {
            $0.buckets.count
        }
    }

    private func normalizedKey(
        for request: Request
    ) -> String? {
        guard
            let key = keyResolver(request),
            !key.isEmpty,
            key.utf8.count
                <= configuration.maxKeyBytes
        else {
            return nil
        }

        return key
    }

    private func keyFailureResult(
        request: Request,
        next: @escaping FastNext
    ) -> MiddlewareResult {
        switch
            configuration
                .keyFailureBehavior
        {
        case .passThrough:
            return next(request)

        case .reject:
            return .response(
                Response.text(
                    "Rate limit key unavailable",
                    status: .tooManyRequests
                )
            )
        }
    }

    private func limitedResponse(
        _ decision: RateLimitDecision
    ) -> Response {
        var response = Response.text(
            "Too Many Requests",
            status: .tooManyRequests
        )

        applyLimitHeaders(
            decision,
            to: &response
        )

        if let retry =
            decision.retryAfterSeconds
        {
            response.headers.replaceOrAdd(
                name: "retry-after",
                value: String(retry)
            )
        }

        return response
    }

    private func applyLimitHeaders(
        _ decision: RateLimitDecision,
        to response: inout Response
    ) {
        response.headers.replaceOrAdd(
            name: "ratelimit-limit",
            value: String(decision.limit)
        )
        response.headers.replaceOrAdd(
            name: "ratelimit-remaining",
            value: String(
                decision.remaining
            )
        )
        response.headers.replaceOrAdd(
            name: "ratelimit-reset",
            value: String(
                decision.resetAfterSeconds
            )
        )
    }

    private func makeDecision(
        allowed: Bool,
        count: Int,
        elapsedNanoseconds: UInt64
    ) -> RateLimitDecision {
        let remainingNanoseconds =
            elapsedNanoseconds
                >= configuration
                    .windowNanoseconds
            ? 0
            : configuration
                .windowNanoseconds
                - elapsedNanoseconds

        let resetSeconds =
            Self.ceilSeconds(
                remainingNanoseconds
            )

        return RateLimitDecision(
            allowed: allowed,
            limit: configuration.limit,
            remaining: max(
                0,
                configuration.limit
                    - count
            ),
            resetAfterSeconds:
                resetSeconds,
            retryAfterSeconds:
                allowed
                ? nil
                : max(1, resetSeconds)
        )
    }

    static func evictionBatch(
        _ maxKeys: Int
    ) -> Int {
        max(1, maxKeys / 8)
    }

    /// Amortized bounded-store eviction: capacity overflow prunes a small
    /// batch of least-recently-touched buckets in one pass instead of
    /// scanning the whole table per inserted key. The store stays bounded
    /// by `maxKeys` — a full table pays one O(n·log batch) scan per batch
    /// of fresh keys, so the per-insert cost stays constant between prunes.
    private static func pruneOldest(
        buckets: inout [String: Bucket],
        count: Int
    ) {
        guard count > 0, buckets.count > 0 else {
            return
        }

        var heap: [Victim] = []
        heap.reserveCapacity(count)

        for (key, bucket) in buckets {
            let candidate = Victim(
                key: key,
                lastTouch: bucket.lastTouch
            )

            if heap.count < count {
                heap.append(candidate)
                heapifyUp(&heap, heap.count - 1)
            } else if
                candidate.lastTouch
                    < heap[0].lastTouch
            {
                // Replace the worst retained victim;
                // ties keep the incumbent.
                heap[0] = candidate
                heapifyDown(&heap, 0)
            }
        }

        while !heap.isEmpty {
            let victim = heap[0]

            heap[0] = heap[
                heap.count - 1
            ]
            heap.removeLast()

            if !heap.isEmpty {
                heapifyDown(&heap, 0)
            }

            buckets.removeValue(
                forKey: victim.key
            )
        }
    }

    private struct Victim: Sendable {
        let key: String
        let lastTouch: UInt64
    }

    private static func heapifyUp(
        _ heap: inout [Victim],
        _ start: Int
    ) {
        var child = start

        while child > 0 {
            let parent = (child - 1) / 2

            if
                heap[child].lastTouch
                    > heap[parent]
                        .lastTouch
            {
                heap.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private static func heapifyDown(
        _ heap: inout [Victim],
        _ start: Int
    ) {
        var parent = start

        while true {
            let left = parent * 2 + 1

            guard left < heap.count else {
                return
            }

            let right = left + 1
            var largest = left

            if
                right < heap.count,
                heap[right].lastTouch
                    > heap[left]
                        .lastTouch
            {
                largest = right
            }

            if
                heap[largest].lastTouch
                    > heap[parent]
                        .lastTouch
            {
                heap.swapAt(
                    parent,
                    largest
                )
                parent = largest
            } else {
                return
            }
        }
    }

    private static func ceilSeconds(
        _ nanoseconds: UInt64
    ) -> Int {
        guard nanoseconds > 0 else {
            return 0
        }

        let seconds =
            (nanoseconds - 1)
                / 1_000_000_000
                + 1

        if seconds
            > UInt64(Int.max)
        {
            return Int.max
        }

        return Int(seconds)
    }
}

public extension Application {
    func use(
        rateLimiter:
            FixedWindowRateLimiter
    ) {
        useFast(
            rateLimiter.middleware()
        )
    }
}
