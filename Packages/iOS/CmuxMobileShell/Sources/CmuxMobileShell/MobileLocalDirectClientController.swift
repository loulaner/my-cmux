public import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
public import CmuxMobileTransport
import Observation
@preconcurrency import Network

/// Single foreground owner of pairing, persistence, reconnect, and the existing-terminal list.
@MainActor @Observable
public final class MobileLocalDirectClientController {
    /// Safe UI failures; never contains a raw network error, endpoint, or capability.
    public enum Failure: Error, Equatable, Sendable {
        case invalidInput, recordUnavailable, needsApproval, hostChanged, saveFailed, incompatibleHost, networkUnavailable
    }
    /// Connection state, independent of terminal rendering (not implemented here).
    public enum State: Equatable, Sendable {
        case disconnected, connecting, waitingApproval, connected, reconnecting, error(Failure)
    }
    /// Generation of the validated shared RPC connection.
    public private(set) var connectionGeneration: UInt64 = 0
    /// Owner of only the selected existing terminal; never exposes a capability token.
    public private(set) var terminalSession: MobileLocalDirectTerminalSession?
    /// Authenticated host theme for the initial renderer, before the first frame.
    public private(set) var terminalTheme: TerminalTheme = .monokai
    @ObservationIgnored private var viewportGeneration: UInt64 = 0
    /// Draft address is never persisted without successful approval and host validation.
    public var address = ""
    /// TCP port draft, initially the Mac direct-host default.
    public var port = "49443"
    /// Current safe connection state.
    public private(set) var state: State = .disconnected
    /// Whether a validated capability was loaded or durably saved.
    public private(set) var isRemembered = false
    /// Existing workspaces and terminal-only rows.
    public private(set) var workspaces: [MobileLocalDirectWorkspace] = []
    /// Server capabilities retained for the later renderer owner.
    public private(set) var capabilities: Set<String> = []
    /// Stable selection survives reconnect; no remote creation is performed.
    public private(set) var selectedWorkspaceID: String?
    /// Existing selected terminal identity for the later renderer.
    public private(set) var selectedSurfaceID: String?

    @ObservationIgnored private let store: any MobileLocalDirectClientStoring
    @ObservationIgnored private let connect: @Sendable (String, Int) async throws -> any CmxByteTransport
    @ObservationIgnored private let admit: @Sendable (any CmxByteTransport, MobileLocalDirectClientRecord?) async throws -> MobileLocalDirectClientConnection
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var record: MobileLocalDirectClientRecord?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var manuallyDisconnected = false
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var rpc: (any MobileSyncing)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var retryWake: AsyncStream<Void>.Continuation?

    #if DEBUG
    @ObservationIgnored private var traceBudget = 160
    private func trace(_ stage: String, error: (any Error)? = nil) {
        guard traceBudget > 0 else { return }
        traceBudget -= 1
        let kind = error.map { MobileLocalDirectFailureDiagnostic($0).kind } ?? "none"
        NSLog("[direct-connection] stage=%@ error=%@", stage, kind)
    }
    #endif

    /// Creates an idle controller without disk, network, or task side effects.
    /// Inject transport/admission and a clock to test business behavior without credentials or live VPNs.
    public init(store: any MobileLocalDirectClientStoring,
                connect: @escaping @Sendable (String, Int) async throws -> any CmxByteTransport = {
                    try await CmxLocalDirectConnector().connect(host: $0, port: $1)
                },
                admit: @escaping @Sendable (any CmxByteTransport, MobileLocalDirectClientRecord?) async throws -> MobileLocalDirectClientConnection = {
                    try await MobileLocalDirectClientConnection.admit(transport: $0, record: $1)
                }, clock: any Clock<Duration> = ContinuousClock()) {
        self.store = store; self.clock = clock
        self.connect = {
                    #if DEBUG
                    NSLog("[direct-connection] connector.begin")
                    #endif
                    do {
                        let stream = try await connect($0, $1)
                        #if DEBUG
                        NSLog("[direct-connection] connector.complete")
                        #endif
                        return stream
                    } catch {
                        #if DEBUG
                        NSLog("[direct-connection] connector.failed error=%@", MobileLocalDirectFailureDiagnostic(error).kind)
                        #endif
                        throw error
                    }

        }
        self.admit = {
                    #if DEBUG
                    NSLog("[direct-connection] admission.begin saved=%d", $1 != nil)
                    #endif
                    do {
                        let connection = try await admit($0, $1)
                        #if DEBUG
                        NSLog("[direct-connection] admission.complete")
                        #endif
                        return connection
                    } catch {
                        #if DEBUG
                        NSLog("[direct-connection] admission.failed error=%@", MobileLocalDirectFailureDiagnostic(error).kind)
                        #endif
                        throw error
                    }

        }
    }

    /// Pauses everything in background. Foreground resumes saved credentials unless manually disconnected.
    public func setForeground(_ active: Bool) async {
        guard active != foreground else { return }
        foreground = active
        #if DEBUG
        trace(active ? "foreground" : "background")
        #endif
        if !active {
            pathMonitor?.cancel(); pathMonitor = nil
            await stop()
        } else {
            startPathMonitor()
            if !manuallyDisconnected { await connectRemembered() }
        }
    }

    /// Explicitly reconnects only the saved Mac, never falls back to pairing.
    public func connectRemembered() async {
        #if DEBUG
        trace("remembered.begin")
        #endif
        let token = await stop()
        guard token == epoch, foreground else { return }
        manuallyDisconnected = false
        do {
            let loaded = try await store.load()
            guard token == epoch, foreground else { return }
            record = loaded; isRemembered = loaded != nil
            guard let loaded else { return }
            address = loaded.host; port = String(loaded.port)
            begin(host: loaded.host, port: loaded.port, saved: loaded)
        } catch {
            guard token == epoch else { return }
            record = nil; isRemembered = false; manuallyDisconnected = true; state = .error(.recordUnavailable)
        }
    }

    /// Requests new explicit Mac approval. Old credentials are replaced only after the new session validates and saves.
    public func pair() async {
        guard let number = Int(port), (try? CmxLocalTCPListenerConfiguration(address: address, port: number)) != nil else {
            state = .error(.invalidInput); return
        }
        let host = address
        let token = await stop()
        guard token == epoch, foreground else { return }
        manuallyDisconnected = false
        begin(host: host, port: number, saved: nil)
    }

    /// Stops this foreground connection until the user explicitly chooses to connect again.
    public func disconnect() async { manuallyDisconnected = true; await stop(releaseTerminalControl: true) }

    /// Forgets this iPad's file only. The Mac's approved-device entry is not revoked by this action.
    public func forget() async {
        manuallyDisconnected = true
        let token = await stop(releaseTerminalControl: true)
        guard token == epoch else { return }
        do {
            try await store.forget()
            guard token == epoch else { return }
            record = nil; isRemembered = false; address = ""; port = "49443"
            workspaces = []; capabilities = []; selectedWorkspaceID = nil; selectedSurfaceID = nil
        } catch { if token == epoch { state = .error(.recordUnavailable) } }
    }

    /// Selects an existing terminal, without sending mutations or starting a renderer.
    public func select(workspaceID: String, surfaceID: String) {
        guard workspaces.contains(where: { $0.id == workspaceID && $0.terminals.contains(where: { $0.id == surfaceID }) }) else { return }
        selectedWorkspaceID = workspaceID; selectedSurfaceID = surfaceID
        reconcileTerminalSession()
    }

    private func reconcileTerminalSession() {
        guard state == .connected, let rpc, let record, let workspaceID = selectedWorkspaceID, let surfaceID = selectedSurfaceID,
              workspaces.contains(where: { $0.id == workspaceID && $0.terminals.contains(where: { $0.id == surfaceID }) }) else {
            terminalSession?.invalidate(); terminalSession = nil; return
        }
        if let session = terminalSession, session.workspaceID == workspaceID, session.surfaceID == surfaceID,
           session.connectionGeneration == connectionGeneration { return }
        terminalSession?.invalidate()
        terminalSession = MobileLocalDirectTerminalSession(rpc: rpc, workspaceID: workspaceID, surfaceID: surfaceID,
            clientID: record.deviceID, connectionGeneration: connectionGeneration, capabilities: capabilities,
            nextViewportGeneration: { [weak self] in
                guard let self else { return UInt64.max }
                self.viewportGeneration &+= 1
                return self.viewportGeneration
            })
    }

    /// Wakes only the current backoff; it cannot create a parallel dial.
    public func networkChanged() { retryWake?.yield(()) }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.networkChanged() } }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "dev.cmux.ipad-direct-retry"))
    }

    private func begin(host: String, port: Int, saved: MobileLocalDirectClientRecord?) {
        let token = epoch
        state = .connecting
        operation = Task { [weak self] in await self?.run(host: host, port: port, saved: saved, epoch: token) }
    }

    private func current(_ token: UInt64) -> Bool { token == epoch && foreground && !Task.isCancelled }

    private func run(host: String, port: Int, saved initial: MobileLocalDirectClientRecord?, epoch token: UInt64) async {
        var saved = initial
        var retries = 0
        while current(token) {
            var active: (any MobileSyncing)?
            var transport: (any CmxByteTransport)?
            do {
                state = retries == 0 ? .connecting : .reconnecting
                let stream = try await connect(host, port)
                transport = stream
                guard current(token) else { await stream.close(); return }
                if saved == nil { state = .waitingApproval }
                let connection = try await admit(stream, saved)
                active = connection.rpc
                guard current(token) else { await connection.rpc.disconnect(); return }
                rpc = connection.rpc
                let statusData = try await request(connection.rpc, "mobile.host.status")
                let (status, hostID) = try validatedStatus(statusData, saved: saved)
                let events = await connection.rpc.subscribe(to: ["workspace.updated"])
                _ = try await request(connection.rpc, "mobile.events.subscribe", params: [
                    "stream_id": UUID().uuidString, "topics": ["workspace.updated"], "event_transport": "control_v1"])
                let list = try await loadList(connection.rpc)
                guard current(token) else { await connection.rpc.disconnect(); return }
                saved = try await savedRecord(saved, connection: connection, host: host, port: port, hostID: hostID)
                guard current(token) else { await connection.rpc.disconnect(); return }
                record = saved; isRemembered = true; workspaces = list; capabilities = Set(status.capabilities)
                terminalTheme = status.theme ?? .monokai
                connectionGeneration &+= 1
                state = .connected; retries = 0
                reconcileTerminalSession()
                try await consumeEvents(events, rpc: connection.rpc, epoch: token)
            } catch {
                guard await retireFailedAttempt(error, active: active, transport: transport,
                                                epoch: token, remembered: saved != nil) else { return }
                let delay = [1, 2, 4, 8, 15][min(retries, 4)]
                retries += 1
                await waitToRetry(seconds: delay)
                continue
            }
            await active?.disconnect()
            return
        }
    }

    private func validatedStatus(_ data: Data, saved: MobileLocalDirectClientRecord?) throws -> (MobileHostStatusResponse, String) {
        guard let status = try? MobileHostStatusResponse.decode(data), let hostID = status.macDeviceID,
              UUID(uuidString: hostID) != nil, status.capabilities.contains("events.v1") else { throw Failure.incompatibleHost }
        if let saved, saved.hostID != hostID { throw Failure.hostChanged }
        return (status, hostID)
    }

    private func savedRecord(_ saved: MobileLocalDirectClientRecord?, connection: MobileLocalDirectClientConnection,
                             host: String, port: Int, hostID: String) async throws -> MobileLocalDirectClientRecord {
        if let saved { return saved }
        let next = try MobileLocalDirectClientRecord(host: host, port: port, hostID: hostID,
                                                    deviceID: connection.deviceID, token: connection.token)
        do { try await store.save(next) } catch { throw Failure.saveFailed }
        return next
    }

    private func consumeEvents(_ events: AsyncStream<MobileEventEnvelope>, rpc: any MobileSyncing,
                               epoch token: UInt64) async throws {
        for await _ in events {
            guard current(token) else { break }
            scheduleRefresh(rpc, epoch: token)
        }
        if current(token) {
            #if DEBUG
            trace("events.ended")
            #endif
            throw MobileShellConnectionError.connectionClosed
        }
    }

    /// Retires exactly this attempt before deciding whether its saved credential can retry.
    private func retireFailedAttempt(_ error: any Error, active: (any MobileSyncing)?,
                                      transport: (any CmxByteTransport)?, epoch token: UInt64,
                                      remembered: Bool) async -> Bool {
        #if DEBUG
        trace("attempt.failed", error: error)
        #endif
        if epoch == token { terminalSession?.invalidate(); terminalSession = nil }
        await active?.disconnect()
        if active == nil { await transport?.close() }
        guard current(token), !manuallyDisconnected else { return false }
        rpc = nil
        refreshTask?.cancel(); refreshTask = nil; refreshAgain = false
        if error is CancellationError { state = .disconnected; return false }
        if let failure = nonRetryableFailure(error) {
            manuallyDisconnected = true; state = .error(failure); return false
        }
        guard remembered else { state = .error(.networkUnavailable); return false }
        state = .reconnecting
        return true
    }

    private func request(_ rpc: any MobileSyncing, _ method: String, params: [String: Any] = [:]) async throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
        #if DEBUG
        trace(method + ".begin")
        #endif
        do {
            let response = try await rpc.sendRequest(bytes, timeoutNanoseconds: nil)
            #if DEBUG
            trace(method + ".complete")
            #endif
            return response
        } catch {
            #if DEBUG
            trace(method + ".failed", error: error)
            #endif
            throw error
        }
    }

    private func loadList(_ rpc: any MobileSyncing) async throws -> [MobileLocalDirectWorkspace] {
        let data = try await request(rpc, "workspace.list")
        guard let list = try? MobileSyncWorkspaceListResponse.decode(data) else { throw Failure.incompatibleHost }
        return list.workspaces.map(MobileLocalDirectWorkspace.init)
    }

    private func scheduleRefresh(_ rpc: any MobileSyncing, epoch token: UInt64) {
        refreshAgain = true
        guard refreshTask == nil else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token, self.refreshGeneration == generation { self.refreshTask = nil } }
            do {
                while self.current(token), self.refreshAgain {
                    self.refreshAgain = false
                    let list = try await self.loadList(rpc)
                    if self.current(token) { self.workspaces = list; self.reconcileTerminalSession() }
                }
            } catch {
                guard self.current(token) else { return }
                #if DEBUG
                self.trace("refresh.failed", error: error)
                #endif
                if let failure = self.nonRetryableFailure(error) {
                    let stopped = await self.stop()
                    guard self.epoch == stopped else { return }
                    self.manuallyDisconnected = true; self.state = .error(failure)
                } else {
                    await rpc.disconnect()
                }
            }
        }
    }

    private func nonRetryableFailure(_ error: any Error) -> Failure? {
        if let failure = error as? Failure { return failure }
        if let admission = error as? CmxLocalDirectAdmission.Failure {
            switch admission {
            case .denied: return .needsApproval
            case .invalidResponse: return .incompatibleHost
            case .connectionLost, .timedOut: return nil
            }
        }
        if let shell = error as? MobileShellConnectionError {
            switch shell {
            case .authorizationFailed, .accountMismatch: return .needsApproval
            case .invalidResponse, .rpcError: return .incompatibleHost
            default: break
            }
        }
        return nil
    }

    private func waitToRetry(seconds: Int) async {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        retryWake = channel.continuation
        defer { retryWake = nil; channel.continuation.finish() }
        let stream = channel.stream
        let clock = clock
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await clock.sleep(for: .seconds(seconds)) }
            group.addTask { for await _ in stream { return } }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - Explicit release and connection teardown
extension MobileLocalDirectClientController {
    @discardableResult private func stop(releaseTerminalControl: Bool = false) async -> UInt64 {
        let previousEpoch = epoch
        let releaseRPC = releaseTerminalControl && state == .connected ? rpc : nil
        terminalSession?.invalidate(); terminalSession = nil
        state = .disconnected
        // Keep the admitted stream alive until the explicit release is acknowledged.
        // Ordinary backgrounding, renderer teardown and connection loss never send this.
        let releaseFailed = !(await self.releaseTerminalControl(using: releaseRPC))
        guard previousEpoch == epoch else { return previousEpoch }
        epoch &+= 1
        let token = epoch
        let old = operation; operation = nil; old?.cancel()
        refreshTask?.cancel(); refreshTask = nil; refreshAgain = false
        let oldRPC = rpc; rpc = nil
        state = .disconnected
        await oldRPC?.disconnect()
        await old?.value
        if releaseFailed, epoch == token { state = .error(.networkUnavailable) }
        return token
    }

    private func releaseTerminalControl(using connection: (any MobileSyncing)?) async -> Bool {
        guard let connection else { return true }
        do {
            let data = try await request(connection, "mobile.terminal.viewport", params: ["clear_all": true])
            let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return response?["cleared"] as? Bool == true
        } catch { return false }
    }

}
