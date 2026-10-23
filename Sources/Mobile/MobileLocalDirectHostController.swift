import CMUXMobileCore
import CmuxMobileTransport
import CmuxSettings
import Foundation
import Observation

/// Single app-owned opt-in host; no listener or storage access occurs during construction.
@MainActor @Observable
final class MobileLocalDirectHostController {
    static let shared = try! MobileLocalDirectHostController(baseURL:
        // Preserve an explicitly isolated home: Foundation rewrites /private/tmp
        // to the /tmp symlink, which our no-follow storage correctly rejects.
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-unidentified")
            .appendingPathComponent("local-direct"))

    typealias ListenerFactory = @Sendable (CmxLocalTCPListenerConfiguration,
        @escaping CmxLocalTCPListener.UnauthenticatedConnectionHandler) -> CmxLocalTCPListener
    private(set) var configuration: MobileLocalDirectHostConfiguration?
    private(set) var state: CmxLocalTCPListener.State = .stopped
    private(set) var devices: [CmxLocalDevice] = []
    private(set) var pendingApproval: String?
    private(set) var allowsPairing = false
    private(set) var hasError = false
    private(set) var busy = false
    private let configurationStore: MobileLocalDirectConfigurationStore
    let credentials: CmxLocalDeviceCredentialStore
    let registry = MobileHostConnectionRegistry()
    private let listenerFactory: ListenerFactory
    private let policyDisabled: @Sendable () -> Bool
    private let clock: any Clock<Duration>
    private var listener: CmxLocalTCPListener?
    private var observation: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var policyObservation: Task<Void, Never>?
    private var pairingTimer: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var approvalID: UUID?
    private var epoch: UInt64 = 0
    private var loaded = false
    private var restored = false
    private var visibleViews: Set<UUID> = []

    init(baseURL: URL, policyDisabled: @escaping @Sendable () -> Bool = { MobileRemoteControlPolicy.isDisabled },
         clock: any Clock<Duration> = ContinuousClock(),
         listenerFactory: @escaping ListenerFactory = { CmxLocalTCPListener(configuration: $0, onUnauthenticatedConnection: $1) }) throws {
        let files = CmxLocalDeviceFileStorage(baseURL: baseURL)
        configurationStore = MobileLocalDirectConfigurationStore(files: files)
        credentials = try CmxLocalDeviceCredentialStore(storage: files, storageScope: "local-mac")
        self.policyDisabled = policyDisabled
        self.clock = clock
        self.listenerFactory = listenerFactory
    }

    func load() async {
        guard !loaded, !busy else { return }
        busy = true
        defer { busy = false }
        if policyObservation == nil {
            policyObservation = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: ManagedDevicePolicy.didChangeNotification) {
                    guard let self, !Task.isCancelled else { return }
                    if self.policyDisabled() { await self.stop() }
                }
            }
        }
        do {
            let saved = try await configurationStore.load()
            try await credentials.load()
            configuration = saved
            devices = await credentials.devices()
            loaded = true
            hasError = false
        } catch { hasError = true; state = .failed }
    }

    func restoreIfEnabled() async {
        guard !restored else { return }
        restored = true
        let token = epoch
        await load()
        guard token == epoch else { return }
        if configuration?.enabled == true { await retry() }
    }

    func apply(address: String, port: String, enabled: Bool) async {
        guard loaded, !busy, var saved = configuration else { return }
        busy = true
        defer { busy = false }
        guard let port = Int(port) else { hasError = true; return }
        saved.address = address.isEmpty ? nil : address
        saved.port = port
        saved.enabled = enabled
        let token = epoch
        do {
            try saved.validate()
            try await configurationStore.save(saved)
            configuration = saved
            hasError = false
            guard epoch == token else { return }
            if enabled { await stop(nextState: .stopped) } else { await stop() }
            guard epoch == token &+ 1 else { return }
            if enabled { await startSaved() }
        } catch { hasError = true }
    }

    func retry() async {
        guard loaded, !busy else { return }
        busy = true
        defer { busy = false }
        let token = epoch &+ 1
        await stop(nextState: .stopped)
        guard epoch == token else { return }
        await startSaved()
    }

    private func startSaved() async {
        guard let saved = configuration, saved.enabled else { return }
        guard !policyDisabled(), let address = saved.address,
              let binding = try? CmxLocalTCPListenerConfiguration(address: address, port: saved.port) else {
            state = .failed; hasError = true; return
        }
        epoch &+= 1
        let token = epoch
        let owner = MobileLocalDirectSessionServer(hostDeviceID: saved.hostID, store: credentials,
            approval: { [weak self] name in
                guard let self, await self.isCurrent(token) else { return false }
                return await self.requestApproval(name)
            },
            isCurrent: { [weak self] in await self?.isCurrent(token) ?? false },
            managedPolicyDisabled: policyDisabled, registry: registry,
            onAdmitted: { [weak self] in await self?.refreshDevices() })
        let next = listenerFactory(binding) { [weak self] transport in
            await owner.serve(transport)
            await self?.refreshDevices()
        }
        listener = next
        let changes = await next.stateUpdates()
        guard epoch == token else { await next.stop(); return }
        observation = Task { [weak self] in
            for await value in changes {
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                if value == .failed {
                    await self.stop(nextState: .failed)
                    return
                }
                self.state = value
            }
        }
        state = .starting
        let start = Task { await next.start() }
        starting = start
        await start.value
        guard epoch == token else { await next.stop(); return }
        let finalState = await next.state
        guard epoch == token else { return }
        starting = nil
        state = finalState
        hasError = state == .failed
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        guard !policyDisabled() else { closePairingWindow(); return false }
        guard epoch == token, configuration?.enabled == true else { return false }
        if case .listening = state { return true }
        return false
    }

    func stop() async {
        let token = epoch &+ 1
        await stop(nextState: .stopped)
        guard epoch == token else { return }
        TerminalController.shared.releaseAllDirectSizingControl(reason: "local_direct.stopped")
    }

    private func stop(nextState: CmxLocalTCPListener.State) async {
        epoch &+= 1
        starting?.cancel()
        starting = nil
        closePairingWindow()
        observation?.cancel()
        observation = nil
        let old = listener
        listener = nil
        state = nextState
        if nextState == .failed { hasError = true }
        let sessions = registry.removeAll()
        await old?.stop()
        for session in sessions { await session.close(reason: "local direct stopped") }
    }

    func viewOpened(_ id: UUID) { visibleViews.insert(id) }
    func viewClosed(_ id: UUID) { visibleViews.remove(id); closePairingWindow() }
    func openPairingWindow() {
        guard !visibleViews.isEmpty, !policyDisabled(), case .listening = state else { return }
        closePairingWindow()
        allowsPairing = true
        pairingTimer = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(60)); self?.closePairingWindow() } catch {}
        }
    }
    func closePairingWindow() {
        allowsPairing = false
        pairingTimer?.cancel()
        pairingTimer = nil
        resolveApproval(false)
    }

    func requestApproval(_ name: String) async -> Bool {
        guard allowsPairing, !visibleViews.isEmpty, !policyDisabled(), approvalID == nil,
              case .listening = state, !Task.isCancelled else { return false }
        let id = UUID()
        approvalID = id
        pendingApproval = name
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { approvalID = nil; pendingApproval = nil; continuation.resume(returning: false) }
                else { approvalContinuation = continuation }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.approvalID == id { self?.resolveApproval(false) } } }
    }
    func resolveApproval(_ allow: Bool) {
        let approved = allow && allowsPairing && !visibleViews.isEmpty && !policyDisabled()
        let continuation = approvalContinuation
        approvalContinuation = nil
        approvalID = nil
        pendingApproval = nil
        continuation?.resume(returning: approved)
    }
    func refreshDevices() async { devices = await credentials.devices() }
    func removeDevice(_ id: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await credentials.revoke(deviceID: id)
            let sessions = registry.removeLocalDirectConnections(deviceID: id)
            for session in sessions { await session.close(reason: "local device revoked") }
            TerminalController.shared.clearMobileViewportReports(clientIDs: [id], reason: "local_direct.revoked")
            await refreshDevices()
            hasError = false
        } catch { hasError = true }
    }
}
