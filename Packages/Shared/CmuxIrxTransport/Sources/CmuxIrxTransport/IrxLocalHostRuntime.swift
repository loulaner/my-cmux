import Foundation
import IrohLib

/// Owns a strict direct-only listener and locally authorized inbound sessions.
///
/// This service does not pair unknown devices or load credentials. The caller
/// owns authorization persistence and invokes ``enforceAuthorizations()`` after
/// changes. Session handlers must honor cancellation and the live authorization check.
public actor IrxLocalHostRuntime {
    /// Safe lifecycle status without native error text or credential data.
    public enum State: Sendable, Equatable {
        /// No active listener is owned.
        case stopped
        /// A new endpoint is binding.
        case starting
        /// A listener is bound to the specified interface and UDP port.
        case listening(boundAddress: String, port: Int)
        /// Binding or accepting failed; explicit start is required to retry.
        case failed(Failure)
    }

    /// Safe failure categories suitable for application presentation.
    public enum Failure: Sendable, Equatable {
        /// The exact requested binding could not become ready.
        case bindFailed
        /// The accept stream ended or failed unexpectedly.
        case acceptFailed
    }

    /// Processes one registered session and receives a live full-tuple authorization check.
    public typealias SessionHandler = @Sendable (
        _ peer: IrxAdmittedPeerInfo, _ control: IrxLaneStream, _ sessionID: String,
        _ connection: IrxConnection, _ stillAuthorized: @escaping @Sendable (String) -> Bool
    ) async -> Void

    /// The latest lifecycle status, readable without starting a listener.
    public private(set) var state: State = .stopped
    private let configuration: IrxLocalHostConfiguration
    private let current: IrxLocalPeerAuthorizationCurrent
    private let journal: IrxJournal
    private let sessionHandler: SessionHandler
    private let acceptInbound: @Sendable (IrxEndpointSupervisor) async -> IrxEndpointSupervisor.AcceptResult
    private let boundSockets: @Sendable (Endpoint) -> [String]
    private let beforeBind: @Sendable () async -> Void
    private var epoch: UInt64 = 0
    private var supervisor: IrxEndpointSupervisor?
    private var registry: IrxServerSessionRegistry?
    private var starting: Task<Void, Never>?
    private var accepting: Task<Void, Never>?
    private var sessions: [UUID: Task<Void, Never>] = [:]

    /// Creates a stopped host with no network or storage side effects.
    ///
    /// - Parameters:
    ///   - configuration: The validated strict bind configuration.
    ///   - current: The sole current local authorization source.
    ///   - journal: An injected transport journal.
    ///   - sessionHandler: Runs only for registered peers; returning closes that connection.
    public init(configuration: IrxLocalHostConfiguration, current: IrxLocalPeerAuthorizationCurrent,
                journal: IrxJournal, sessionHandler: @escaping SessionHandler) {
        self.init(configuration: configuration, current: current, journal: journal,
            beforeBind: {}, sessionHandler: sessionHandler)
    }

    /// Injects a deterministic startup suspension for lifecycle tests.
    init(configuration: IrxLocalHostConfiguration, current: IrxLocalPeerAuthorizationCurrent,
         journal: IrxJournal, beforeBind: @escaping @Sendable () async -> Void,
         acceptInbound: @escaping @Sendable (IrxEndpointSupervisor) async -> IrxEndpointSupervisor.AcceptResult = {
             await $0.acceptNextInboundResult()
         },
         boundSockets: @escaping @Sendable (Endpoint) -> [String] = { $0.boundSockets() },
         sessionHandler: @escaping SessionHandler) {
        self.configuration = configuration
        self.current = current
        self.journal = journal
        self.beforeBind = beforeBind
        self.acceptInbound = acceptInbound
        self.boundSockets = boundSockets
        self.sessionHandler = sessionHandler
    }

    /// Starts or joins one binding attempt; repeated calls do not duplicate listeners.
    ///
    /// Failures are exposed through ``state``. After stop or failure, an explicit
    /// call constructs a fresh supervisor rather than reviving a deactivated one.
    public func start() async {
        if let starting { await starting.value; return }
        if case .listening = state { return }
        epoch &+= 1
        let token = epoch
        let endpoint = IrxEndpointSupervisor(configuration: configuration.endpointConfiguration, journal: journal)
        let registry = IrxServerSessionRegistry(journal: journal)
        supervisor = endpoint
        self.registry = registry
        state = .starting
        let task = Task { await self.bind(endpoint, registry: registry, epoch: token) }
        starting = task
        await task.value
        if epoch == token { starting = nil }
    }

    /// Invalidates startup, cancels all processing, and closes the owned endpoint and sessions.
    public func stop() async { await shutDown(state: .stopped) }

    /// Rechecks complete admitted tuples and closes revoked or changed live sessions.
    public func enforceAuthorizations() async { await registry?.closeUnauthorized(code: .revoked) }

    /// Forwards a platform network-change notification without scanning or discovery.
    public func notifyNetworkChange() async { await supervisor?.notifyNetworkChange() }

    /// Returns the existing loop task for deterministic completion observation in tests.
    func acceptLoopForTesting() -> Task<Void, Never>? { accepting }

    private func bind(_ endpoint: IrxEndpointSupervisor, registry: IrxServerSessionRegistry, epoch token: UInt64) async {
        await beforeBind()
        guard token == epoch, !Task.isCancelled else { await endpoint.deactivate(); return }
        do {
            let native = try await endpoint.readyEndpoint(credentials: [])
            guard token == epoch, !Task.isCancelled else { await endpoint.deactivate(); return }
            let port = try IrxLocalHostBindingValidation().port(sockets: boundSockets(native),
                requestedAddress: configuration.address, requestedPort: configuration.port)
            guard token == epoch, !Task.isCancelled else { await endpoint.deactivate(); return }
            state = .listening(boundAddress: configuration.address, port: port)
            accepting = Task { await self.accept(endpoint, registry: registry, epoch: token) }
        } catch {
            guard token == epoch else { return }
            await shutDown(state: .failed(.bindFailed))
        }
    }

    private func accept(_ endpoint: IrxEndpointSupervisor, registry: IrxServerSessionRegistry, epoch token: UInt64) async {
        while token == epoch, !Task.isCancelled {
            let result = await acceptInbound(endpoint)
            guard token == epoch, !Task.isCancelled else {
                if case .accepted(let inbound) = result {
                    switch inbound {
                    case .irx(let connection):
                        await connection.close(code: .userRequested, origin: .local)
                    case .foreign(_, let connection):
                        try? connection.close(errorCode: 0, reason: Data())
                    }
                }
                return
            }
            let inbound: IrxEndpointSupervisor.AcceptedInbound
            switch result {
            case .handshakeFailed:
                // One native incoming attempt was consumed; await the next one.
                continue
            case .closed:
                await shutDown(state: .failed(.acceptFailed))
                return
            case .accepted(let accepted):
                inbound = accepted
            }
            switch inbound {
            case .foreign(_, let connection):
                try? connection.close(errorCode: 0, reason: Data())
            case .irx(let connection):
                guard token == epoch, !Task.isCancelled else {
                    await connection.close(code: .userRequested, origin: .local)
                    return
                }
                let id = UUID()
                sessions[id] = Task {
                    await self.serve(connection, registry: registry, epoch: token)
                    self.sessions[id] = nil
                }
            }
        }
    }

    private func serve(_ connection: IrxConnection, registry: IrxServerSessionRegistry, epoch token: UInt64) async {
        let judgment = IrxLocalPeerJudge(current: current).judgment()
        guard let (peer, control, sessionID) = await IrxAdmission().performServer(
            connection: connection, judgment: judgment, journal: journal) else { return }
        let authorized: @Sendable (String) -> Bool = { key in
            (try? judgment(nil, key)) == peer
        }
        guard token == epoch, !Task.isCancelled else {
            await connection.close(code: .userRequested, origin: .local)
            return
        }
        let registered = await registry.admit(deviceID: peer.deviceID, sessionID: sessionID,
            connection: connection, stillAuthorized: authorized)
        let closed = await connection.isConnectionClosed()
        if registered, !closed, token == epoch, !Task.isCancelled, authorized(connection.remoteEndpointIDHex) {
            await sessionHandler(peer, control, sessionID, connection, authorized)
        }
        await connection.close(code: .userRequested, origin: .local)
        await registry.remove(deviceID: peer.deviceID, sessionID: sessionID)
    }

    private func shutDown(state nextState: State) async {
        epoch &+= 1
        let endpoint = supervisor
        let registry = registry
        supervisor = nil
        self.registry = nil
        starting?.cancel()
        starting = nil
        accepting?.cancel()
        accepting = nil
        for task in sessions.values { task.cancel() }
        sessions.removeAll()
        state = nextState
        await endpoint?.deactivate()
        await registry?.closeAll(code: .userRequested)
    }
}
