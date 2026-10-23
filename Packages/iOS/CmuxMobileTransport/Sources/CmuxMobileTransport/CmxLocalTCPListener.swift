public import CMUXMobileCore
import Foundation
import Dispatch
@preconcurrency import Network

/// A strictly bound TCP listener whose connections remain unauthenticated.
///
/// Production startup requires live system VPN interface evidence. This is not
/// cryptographic Tailscale node identity or device approval; no RPC is exposed.
/// No Bonjour service, relay, alternate bind, or automatic retry is configured.
public actor CmxLocalTCPListener {
    /// Observable listener lifecycle.
    public enum State: Sendable, Equatable {
        /// No listener is active.
        case stopped
        /// Waiting for Network.framework readiness.
        case starting
        /// Bound to the explicit address and effective TCP port.
        case listening(address: String, port: Int)
        /// Startup or listener operation failed without retry.
        case failed
    }

    /// Receives an endpoint-checked but unauthenticated byte stream.
    /// Returning closes the stream; handlers must cooperate with cancellation.
    public typealias UnauthenticatedConnectionHandler = @Sendable (any CmxByteTransport) async -> Void

    /// The current state; reading it never opens sockets.
    public private(set) var state: State = .stopped {
        didSet { stateChannel.continuation.yield(state) }
    }
    private let stateChannel = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))

    /// Supplies lifecycle changes to the single owning controller without polling.
    /// - Returns: Current state followed by subsequent transitions; use one consumer per listener.
    public func stateUpdates() -> AsyncStream<State> {
        stateChannel.continuation.yield(state)
        return stateChannel.stream
    }
    private let configuration: CmxLocalTCPListenerConfiguration
    private let handler: UnauthenticatedConnectionHandler
    // Network.framework requires a delivery queue; all ownership is actor-isolated.
    private let callbackQueue = DispatchQueue(label: "dev.cmux.local-tcp-listener")
    private var listener: NWListener?
    private var epoch: UInt64 = 0
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var transports: [UUID: CmxLocalTCPGuardedTransport] = [:]
    private let makeAuthority: @Sendable () -> any CmxLocalTCPRouteAuthorizing
    private var authority: (any CmxLocalTCPRouteAuthorizing)?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Creates a stopped listener without network or storage side effects.
    /// - Parameters:
    ///   - configuration: Exact local IPv4 binding.
    ///   - onUnauthenticatedConnection: Owns authentication, not business admission.
    public init(configuration: CmxLocalTCPListenerConfiguration,
                onUnauthenticatedConnection: @escaping UnauthenticatedConnectionHandler) {
        self.configuration = configuration
        handler = onUnauthenticatedConnection
        if configuration.permitsLoopbackForTesting {
            makeAuthority = { CmxLocalTCPLoopbackRouteAuthority() }
        } else {
            makeAuthority = { CmxLocalTCPSystemRouteAuthority() }
        }
    }

    /// Internal injection keeps controlled route tests away from the system network.
    init(configuration: CmxLocalTCPListenerConfiguration,
         makeAuthority: @escaping @Sendable () -> any CmxLocalTCPRouteAuthorizing,
         onUnauthenticatedConnection: @escaping UnauthenticatedConnectionHandler) {
        self.configuration = configuration
        self.makeAuthority = makeAuthority
        handler = onUnauthenticatedConnection
    }

    /// Starts or joins a single readiness attempt; inspect ``state`` for its outcome.
    /// Stop and failure release every waiting caller. Retry requires an explicit call.
    public func start() async {
        if case .listening = state { return }
        if state == .starting {
            await withCheckedContinuation { starters.append($0) }
            return
        }
        epoch &+= 1
        let token = epoch
        state = .starting
        let authority = makeAuthority()
        self.authority = authority
        do {
            let requiredInterface = try await authority.prepare(address: configuration.address) { [weak self] in
                await self?.routeInvalidated(epoch: token)
            }
            guard token == epoch, !Task.isCancelled else {
                if token == epoch { await shutDown(nextState: .failed) }
                return
            }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            guard let address = IPv4Address(configuration.address),
                  let port = NWEndpoint.Port(rawValue: UInt16(exactly: configuration.port) ?? 0) else {
                state = .failed
                return
            }
            parameters.requiredInterface = requiredInterface
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: port)
            let native = try NWListener(using: parameters)
            listener = native
            native.stateUpdateHandler = { [weak self] status in
                Task { await self?.updated(status, epoch: token) }
            }
            native.newConnectionHandler = { [weak self] connection in
                Task {
                    guard let self else { connection.cancel(); return }
                    await self.accept(connection, epoch: token)
                }
            }
            await withCheckedContinuation { continuation in
                starters.append(continuation)
                native.start(queue: callbackQueue)
            }
        } catch {
            guard token == epoch else { return }
            await shutDown(nextState: .failed)
        }
    }

    private func routeInvalidated(epoch token: UInt64) async {
        guard token == epoch else { return }
        await shutDown(nextState: .failed)
    }

    /// Cancels the listener, pending connects, and all streams owned by this instance.
    public func stop() async { await shutDown(nextState: .stopped) }

    private func updated(_ status: NWListener.State, epoch token: UInt64) async {
        guard token == epoch else { return }
        switch status {
        case .ready:
            guard let port = listener?.port, port.rawValue > 0,
                  configuration.port == 0 || Int(port.rawValue) == configuration.port else {
                await shutDown(nextState: .failed)
                return
            }
            state = .listening(address: configuration.address, port: Int(port.rawValue))
            finishStarters()
        case .failed, .waiting:
            await shutDown(nextState: .failed)
        case .cancelled:
            await shutDown(nextState: .stopped)
        case .setup: break
        @unknown default:
            await shutDown(nextState: .failed)
        }
    }

    private func accept(_ connection: NWConnection, epoch token: UInt64) async {
        guard token == epoch, case let .listening(_, port) = state else { connection.cancel(); return }
        let id = UUID()
        let base = CmxNetworkByteTransport(acceptedConnection: connection)
        let transport = CmxLocalTCPGuardedTransport(base: base) { [weak self] in
            guard let self else { throw CmxLocalTCPRouteProof.Failure.unavailable }
            try await self.validate(connection, port: port, epoch: token)
        }
        transports[id] = transport
        tasks[id] = Task {
            do {
                try await transport.connect()
                guard self.epoch == token, !Task.isCancelled else {
                    await self.finish(id, transport: transport)
                    return
                }
                await self.handler(transport)
            } catch { /* Unready or cancelled connections never reach authentication. */ }
            await self.finish(id, transport: transport)
        }
    }

    private func validate(_ connection: NWConnection, port: Int, epoch token: UInt64) async throws {
        guard token == epoch, case .listening = state, let authority else {
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
        try await authority.validate(path: connection.currentPath, port: port)
        guard token == epoch, case .listening = state else { throw CmxLocalTCPRouteProof.Failure.unavailable }
    }

    private func finish(_ id: UUID, transport: CmxLocalTCPGuardedTransport) async {
        await transport.close()
        transports[id] = nil
        tasks[id] = nil
    }

    private func finishStarters() {
        let waiting = starters
        starters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    private func shutDown(nextState: State) async {
        epoch &+= 1
        let stoppingAuthority = authority
        authority = nil
        listener?.cancel()
        listener = nil
        state = nextState
        finishStarters()
        let closing = Array(transports.values)
        transports.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for transport in closing { await transport.close() }
        await stoppingAuthority?.stop()
    }
}
