import CmuxCloud
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import OSLog

nonisolated private let deviceDirectoryLog = Logger(subsystem: "dev.cmux", category: "device-directory")

/// The account's discoverable Macs, authorized by the Mac directory and enriched
/// with saved pairings and registry metadata. An unavailable discovery client
/// never makes those secondary sources authoritative.
/// Bound to one account generation. Team-scoped registry enrichment may fail
/// and is never allowed to remove an account-owned row. The registry is read
/// on start, explicit refresh, and authenticated directory changes; it is not
/// polled and does not establish whether a device is online.
@MainActor
@Observable
final class DeviceDirectory {
    static let didChangeNotification = Notification.Name("cmux.devices.directoryDidChange")

    private(set) var records: [DeviceDirectoryRecord] = []
    private(set) var isRunning = false
    private(set) var registryError: String?
    private(set) var hasLoadedRegistry = false
    private(set) var isRefreshingRegistry = false
    /// The revision of the v2 directory the last registry read observed; the
    /// provider registry retries host refusals when it advances.
    private(set) var directoryStamp: DeviceDirectoryStamp?

    /// Notifications describe the whole UI snapshot, not only its rows. A
    /// status transition is observable even when the directory stays empty.
    private struct PublishedState: Equatable {
        let records: [DeviceDirectoryRecord]
        let isRunning: Bool
        let registryError: String?
        let hasLoadedRegistry: Bool
        let isRefreshingRegistry: Bool
        let directoryStamp: DeviceDirectoryStamp?
    }

    private var lastPublishedState: PublishedState?

    private let identity: AuthenticatedSessionIdentity
    private let teamID: String?
    private let pairing: any DeviceLinkAuthorizationSource
    private let registryClient: DeviceRegistryDirectoryClient
    private let automaticClient: DeviceIrxClient?
    private var authenticatedMacs: [DeviceDiscoveredMac] = []
    private var directoryChangesTask: Task<Void, Never>?
    private let fixedSelfInstance: SurfaceDeviceInstanceID?
    private var selfInstance: SurfaceDeviceInstanceID {
        fixedSelfInstance ?? SurfaceDeviceInstanceID(deviceID: MobileHostIdentity.deviceID(), tag: MobileHostIdentity.instanceTag())
    }

    private var registryDevices: [DeviceRegistryDirectoryClient.Device] = []
    private var registryTask: Task<Void, Never>?
    private var registryGeneration: UInt64 = 0
    private var pairingObserver: NSObjectProtocol?
    init(
        auth: AuthCoordinator,
        identity: AuthenticatedSessionIdentity,
        teamID: String?,
        pairing: any DeviceLinkAuthorizationSource,
        registryClient: DeviceRegistryDirectoryClient? = nil,
        automaticClient: DeviceIrxClient? = nil,
        selfInstance: SurfaceDeviceInstanceID? = nil
    ) {
        self.identity = identity
        self.teamID = teamID
        self.pairing = pairing
        self.automaticClient = automaticClient
        let accountDirectoryEnabled = AccountMacDirectoryFeature.isEnabled()
        let tokens = accountDirectoryEnabled
            ? HiveAccountTokenSource(accountScopedAuth: auth, identity: identity)
            : HiveAccountTokenSource(auth: auth, identity: identity, teamID: teamID)
        self.registryClient = registryClient ?? DeviceRegistryDirectoryClient(
            session: { try await tokens.session() },
            // The account directory has no selected-team partition. The
            // registry is enrichment only, so do not pin it to the team that
            // happened to be selected when this account-scoped directory was
            // created. The rollback path keeps the team header.
            teamID: accountDirectoryEnabled ? nil : teamID
        )
        self.fixedSelfInstance = selfInstance
    }

    /// What a team switch carries into the next team's directory so My Devices
    /// keeps its rows while the new team's sources load. Membership is the
    /// account's (the per-user directory), so only team-scoped reads restart.
    struct CarriedState: Sendable {
        var records: [DeviceDirectoryRecord]
        var registryDevices: [DeviceRegistryDirectoryClient.Device]
        var authenticatedMacs: [DeviceDiscoveredMac]
        var hasLoadedRegistry: Bool
    }

    func carriedState() -> CarriedState {
        CarriedState(records: records, registryDevices: registryDevices, authenticatedMacs: authenticatedMacs,
            hasLoadedRegistry: hasLoadedRegistry)
    }

    /// Seeds a not-yet-started directory for the same account from the
    /// previous team's directory. Ignored once started.
    func adopt(_ carried: CarriedState) {
        guard !isRunning else { return }
        records = carried.records
        registryDevices = carried.registryDevices
        authenticatedMacs = carried.authenticatedMacs
        hasLoadedRegistry = carried.hasLoadedRegistry
        notifyChanged()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pairingObserver = NotificationCenter.default.addObserver(
            forName: pairing.authorizationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remerge() }
        }
        remerge()
        refreshRegistry()
        if let automaticClient {
            directoryChangesTask = Task { [weak self] in
                for await _ in await automaticClient.directoryChanges() {
                    guard !Task.isCancelled else { return }
                    // Await an older refresh before reading a newer pushed revision.
                    await self?.registryTask?.value
                    guard !Task.isCancelled else { return }
                    await self?.refreshRegistry().value
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if let pairingObserver { NotificationCenter.default.removeObserver(pairingObserver) }
        pairingObserver = nil
        directoryChangesTask?.cancel()
        directoryChangesTask = nil
        authenticatedMacs = []
        registryGeneration &+= 1
        registryTask?.cancel()
        registryTask = nil
        isRefreshingRegistry = false
        registryDevices = []
        records = []
        hasLoadedRegistry = false
        registryError = nil
        directoryStamp = nil
        notifyChanged()
    }

    /// The explicit Refresh verb: re-read registry and authenticated discovery now.
    @discardableResult
    func refreshRegistry() -> Task<Void, Never> {
        if let registryTask { return registryTask }
        isRefreshingRegistry = true
        notifyChanged()
        registryGeneration &+= 1
        let generation = registryGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.registryGeneration {
                    self.isRefreshingRegistry = false
                    self.registryTask = nil
                    self.remerge()
                }
            }
            guard !Task.isCancelled else { return }
            do {
                let devices = try await self.registryClient.list()
                guard !Task.isCancelled else { return }
                self.registryDevices = devices
                self.registryError = nil
            } catch DeviceRegistryDirectoryClient.ListError.notSignedIn {
                guard !Task.isCancelled else { return }
                self.registryError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.registryError = String(localized: "devices.registry.failed", defaultValue: "Could not refresh your Macs. Check your connection and try again.")
                deviceDirectoryLog.error("device registry list failed: \(String(describing: error), privacy: .private)")
            }
            if let automaticClient = self.automaticClient {
                do {
                    let bindings = try await automaticClient.discoverMacs()
                    let stamp = await automaticClient.directoryStamp()
                    guard !Task.isCancelled else { return }
                    self.authenticatedMacs = bindings
                    self.directoryStamp = stamp
                    self.registryError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    // An outage retains the last authenticated rows; per-session
                    // leases reject stale or revoked peers before application I/O.
                }
            }
            self.hasLoadedRegistry = true
        }
        registryTask = task
        return task
    }

    private func remerge() {
        let merged = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            registry: registryDevices,
            authenticatedMacs: authenticatedMacs,
            requiresAuthenticatedDiscovery: true,
            paired: pairing.pairedDevices,
            previous: records,
            selfInstance: selfInstance,
            currentUserID: identity.accountID,
            resolvedTeamID: teamID
        ))
        if merged != records { records = merged }
        notifyChanged()
    }

    private func notifyChanged() {
        let state = PublishedState(
            records: records,
            isRunning: isRunning,
            registryError: registryError,
            hasLoadedRegistry: hasLoadedRegistry,
            isRefreshingRegistry: isRefreshingRegistry,
            directoryStamp: directoryStamp
        )
        guard state != lastPublishedState else { return }
        lastPublishedState = state
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
