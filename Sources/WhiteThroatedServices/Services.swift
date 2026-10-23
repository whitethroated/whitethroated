import NIOConcurrencyHelpers

/// A typed identity for an application service.
///
/// The name is the registry key. Register only one value for a given name, even
/// when two keys use different value types.
public struct ServiceKey<Value: Sendable>:
    Sendable,
    Hashable,
    CustomStringConvertible
{
    public let name: String

    public var description: String {
        name
    }

    public init(_ name: String) {
        precondition(
            !name.isEmpty,
            "Service key name must not be empty"
        )

        self.name = name
    }

    public static func == (
        lhs: ServiceKey<Value>,
        rhs: ServiceKey<Value>
    ) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(
        into hasher: inout Hasher
    ) {
        hasher.combine(name)
    }
}

public enum ServiceRegistryError:
    Error,
    Sendable,
    Equatable
{
    case duplicateKey(String)
    case alreadyStarted
    case missingService(String)
}

/// Setup-time registry for application-owned services.
///
/// Registration is mutable until ``start()``. Starting instantiates factories
/// and returns an immutable ``ServiceContainer``. Requests should resolve
/// services once while handlers are configured, not through a global lookup on
/// every request.
public final class ServiceRegistry:
    Sendable
{
    public typealias ShutdownHook =
        @Sendable () async throws -> Void

    private enum Registration: Sendable {
        case value(any Sendable)
        case factory(@Sendable () -> any Sendable)
    }

    private struct Entry: Sendable {
        let name: String
        let registration: Registration
    }

    private struct State: Sendable {
        var started = false
        var entries: [Entry] = []
        var names: Set<String> = []
        var shutdownHooks: [ShutdownHook] = []
    }

    private let state =
        NIOLockedValueBox(State())

    public init() {}

    /// Register an already-created application singleton.
    public func register<Value: Sendable>(
        _ value: Value,
        for key: ServiceKey<Value>
    ) throws {
        try register(
            key,
            registration: .value(value)
        )
    }

    /// Register a setup-time factory. The factory runs exactly once when the
    /// registry starts.
    public func register<Value: Sendable>(
        _ key: ServiceKey<Value>,
        factory: @escaping @Sendable () -> Value
    ) throws {
        try register(
            key,
            registration: .factory {
                factory()
            }
        )
    }

    /// Register an application-level shutdown hook.
    ///
    /// Hooks run in reverse registration order when the started container is
    /// shut down. Register hooks after the resources they close have been
    /// created, or close dependencies from the hook itself.
    public func onShutdown(
        _ hook: @escaping ShutdownHook
    ) throws {
        try state.withLockedValue {
            state in

            guard !state.started else {
                throw ServiceRegistryError
                    .alreadyStarted
            }

            state.shutdownHooks.append(
                hook
            )
        }
    }

    /// Freeze the registry, instantiate all factories, and return the typed
    /// application container.
    public func start() throws -> ServiceContainer {
        let snapshot =
            try state.withLockedValue {
                state -> (
                    [Entry],
                    [ShutdownHook]
                ) in

                guard !state.started else {
                    throw ServiceRegistryError
                        .alreadyStarted
                }

                state.started = true
                return (
                    state.entries,
                    state.shutdownHooks
                )
            }

        var services:
            [String: any Sendable] = [:]
        services.reserveCapacity(
            snapshot.0.count
        )

        for entry in snapshot.0 {
            switch entry.registration {
            case .value(let value):
                services[entry.name] =
                    value

            case .factory(let factory):
                services[entry.name] =
                    factory()
            }
        }

        return ServiceContainer(
            services: services,
            shutdownHooks:
                snapshot.1.reversed()
        )
    }

    private func register<Value: Sendable>(
        _ key: ServiceKey<Value>,
        registration: Registration
    ) throws {
        try state.withLockedValue {
            state in

            guard !state.started else {
                throw ServiceRegistryError
                    .alreadyStarted
            }

            guard state.names.insert(key.name).inserted else {
                throw ServiceRegistryError
                    .duplicateKey(key.name)
            }

            state.entries.append(
                Entry(
                    name: key.name,
                    registration: registration
                )
            )
        }
    }
}

/// Immutable application service container produced by ``ServiceRegistry``.
public final class ServiceContainer:
    Sendable
{
    public typealias ShutdownHook =
        ServiceRegistry.ShutdownHook

    private let services:
        [String: any Sendable]
    private let shutdownHooks:
        [ShutdownHook]
    private let shutdownTask =
        NIOLockedValueBox<Task<Void, Error>?>(
            nil
        )
    private struct HookRunState:
        Sendable
    {
        var inProgress = false
    }
    private let hookRunState =
        NIOLockedValueBox(
            HookRunState()
        )

    init(
        services: [String: any Sendable],
        shutdownHooks: [ShutdownHook]
    ) {
        self.services = services
        self.shutdownHooks =
            shutdownHooks
    }

    public func resolve<Value: Sendable>(
        _ key: ServiceKey<Value>
    ) -> Value? {
        services[key.name] as? Value
    }

    public func require<Value: Sendable>(
        _ key: ServiceKey<Value>
    ) throws -> Value {
        guard let value = resolve(key) else {
            throw ServiceRegistryError
                .missingService(key.name)
        }

        return value
    }

    /// Run all shutdown hooks once, in reverse registration order.
    ///
    /// Concurrent and repeated calls await the same shutdown operation. A
    /// call made from inside a running hook is part of that operation and
    /// returns immediately instead of awaiting its own completion — the
    /// original caller observes every hook run and the first hook error is
    /// rethrown.
    public func shutdown() async throws {
        let inProgress =
            hookRunState.withLockedValue {
                $0.inProgress
            }

        guard !inProgress else {
            return
        }

        let task =
            shutdownTask.withLockedValue {
                task in

                if let task {
                    return task
                }

                let hooks =
                    shutdownHooks
                let newTask = Task {
                    hookRunState.withLockedValue {
                        $0.inProgress = true
                    }

                    defer {
                        hookRunState
                            .withLockedValue {
                                $0.inProgress =
                                    false
                            }
                    }

                    var firstError: Error?

                    for hook in hooks {
                        do {
                            try await hook()
                        } catch {
                            if firstError == nil {
                                firstError = error
                            }
                        }
                    }

                    if let firstError {
                        throw firstError
                    }
                }

                task = newTask
                return newTask
            }

        try await task.value
    }
}
