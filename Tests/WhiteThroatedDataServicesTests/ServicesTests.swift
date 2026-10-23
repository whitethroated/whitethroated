import NIOConcurrencyHelpers
import WhiteThroated
import WhiteThroatedLifecycle
import WhiteThroatedServices
import XCTest

final class ServicesTests: XCTestCase {
    func testFactoriesRunOnceAtStartAndResolveTypedValues() throws {
        let calls =
            NIOLockedValueBox(0)
        let registry =
            ServiceRegistry()
        let key =
            ServiceKey<Int>("services.test.value")

        try registry.register(key) {
            calls.withLockedValue {
                $0 += 1
            }
            return 42
        }

        let container =
            try registry.start()

        XCTAssertEqual(
            calls.withLockedValue { $0 },
            1
        )
        XCTAssertEqual(
            try container.require(key),
            42
        )
        XCTAssertEqual(
            container.resolve(key),
            42
        )

        XCTAssertThrowsError(
            try registry.start()
        ) {
            XCTAssertEqual(
                $0 as? ServiceRegistryError,
                .alreadyStarted
            )
        }
    }

    func testReentrantShutdownHookDoesNotDeadlock() async throws {
        // A hook that calls container.shutdown() is re-entering the
        // operation it is already part of; awaiting itself again must
        // never happen. The re-entrant call returns immediately and the
        // original caller completes the shutdown.
        let registry =
            ServiceRegistry()

        try registry.register(
            "value",
            for: ServiceKey<String>(
                "services.test.reentrant"
            )
        )

        let heldHookContainer =
            NIOLockedValueBox<ServiceContainer?>(nil)
        let rootShutdownStarted =
            NIOLockedValueBox(false)
        let rootShutdownCompleted =
            NIOLockedValueBox(false)

        try registry.onShutdown {
            rootShutdownStarted.withLockedValue {
                $0 = true
            }

            let heldContainer =
                heldHookContainer.withLockedValue {
                    $0
                }

            if let heldContainer {
                try await heldContainer
                    .shutdown()
            }

            rootShutdownCompleted.withLockedValue {
                $0 = true
            }
        }

        let container = try registry.start()
        heldHookContainer.withLockedValue {
            $0 = container
        }

        try await container.shutdown()

        XCTAssertTrue(
            rootShutdownStarted.withLockedValue {
                $0
            }
        )
        XCTAssertTrue(
            rootShutdownCompleted.withLockedValue {
                $0
            }
        )
    }

    func testValuesCanBeRegisteredDirectly() throws {
        let key =
            ServiceKey<String>("services.test.direct")
        let registry =
            ServiceRegistry()

        try registry.register(
            "ready",
            for: key
        )

        let container =
            try registry.start()

        XCTAssertEqual(
            container.resolve(key),
            "ready"
        )
    }

    func testDuplicateNamesAreRejectedAcrossTypes() throws {
        let registry =
            ServiceRegistry()
        let text =
            ServiceKey<String>("services.test.duplicate")
        let number =
            ServiceKey<Int>("services.test.duplicate")

        try registry.register(
            "value",
            for: text
        )

        XCTAssertThrowsError(
            try registry.register(
                1,
                for: number
            )
        ) {
            XCTAssertEqual(
                $0 as? ServiceRegistryError,
                .duplicateKey(
                    "services.test.duplicate"
                )
            )
        }
    }

    func testRegistrationAfterStartIsRejected() throws {
        let registry =
            ServiceRegistry()
        let key =
            ServiceKey<Int>("services.test.late")
        _ = try registry.start()

        XCTAssertThrowsError(
            try registry.register(
                1,
                for: key
            )
        ) {
            XCTAssertEqual(
                $0 as? ServiceRegistryError,
                .alreadyStarted
            )
        }

        XCTAssertThrowsError(
            try registry.onShutdown {}
        ) {
            XCTAssertEqual(
                $0 as? ServiceRegistryError,
                .alreadyStarted
            )
        }
    }

    func testMissingServiceThrows() throws {
        let registry =
            ServiceRegistry()
        let container =
            try registry.start()
        let key =
            ServiceKey<Int>("services.test.missing")

        XCTAssertNil(
            container.resolve(key)
        )
        XCTAssertThrowsError(
            try container.require(key)
        ) {
            XCTAssertEqual(
                $0 as? ServiceRegistryError,
                .missingService(
                    "services.test.missing"
                )
            )
        }
    }

    func testShutdownRunsInReverseOrderOnce() async throws {
        let order =
            NIOLockedValueBox<[Int]>([])
        let registry =
            ServiceRegistry()

        try registry.onShutdown {
            order.withLockedValue {
                $0.append(1)
            }
        }
        try registry.onShutdown {
            try await Task.sleep(
                nanoseconds: 1_000
            )
            order.withLockedValue {
                $0.append(2)
            }
        }
        try registry.onShutdown {
            order.withLockedValue {
                $0.append(3)
            }
        }

        let container =
            try registry.start()

        try await container.shutdown()
        try await container.shutdown()

        XCTAssertEqual(
            order.withLockedValue { $0 },
            [3, 2, 1]
        )
    }

    func testShutdownRunsEveryHookAndRethrowsFirstError()
        async throws
    {
        struct TestError: Error {}

        let order =
            NIOLockedValueBox<[Int]>([])
        let registry =
            ServiceRegistry()

        try registry.onShutdown {
            order.withLockedValue {
                $0.append(1)
            }
        }
        try registry.onShutdown {
            order.withLockedValue {
                $0.append(2)
            }
            throw TestError()
        }
        try registry.onShutdown {
            order.withLockedValue {
                $0.append(3)
            }
        }

        let container =
            try registry.start()

        do {
            try await container.shutdown()
            XCTFail(
                "Expected shutdown to throw"
            )
        } catch {
            XCTAssertTrue(
                error is TestError
            )
        }

        XCTAssertEqual(
            order.withLockedValue { $0 },
            [3, 2, 1]
        )
    }

    func testLifecycleRunsSyncAndAsyncCleanupInReverseOrder()
        async throws
    {
        let order =
            NIOLockedValueBox<[Int]>([])
        let controller =
            LifecycleController()
        let application =
            Application()

        controller.registerCleanup {
            order.withLockedValue {
                $0.append(1)
            }
        }
        controller.registerAsyncCleanup {
            try await Task.sleep(
                nanoseconds: 1_000
            )
            order.withLockedValue {
                $0.append(2)
            }
        }
        controller.registerCleanup {
            order.withLockedValue {
                $0.append(3)
            }
        }

        try await controller.shutdown(
            application: application,
            drainTimeoutNanoseconds: 0
        )

        XCTAssertEqual(
            order.withLockedValue { $0 },
            [3, 2, 1]
        )
    }
}
