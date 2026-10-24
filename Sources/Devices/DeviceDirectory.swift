import CmuxCloud
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// The account's discoverable Macs, admitted only by authenticated discovery.
/// Saved pairings and previous records enrich admitted rows, never add peers.
/// Bound to one account generation. Discovery failures preserve known rows;
/// per-session leases still reject stale or revoked peers before application I/O.
/// Refreshes run on start, explicit refresh, and authenticated directory changes.
@MainActor
@Observable
final class DeviceDirectory {
    static let didChangeNotification = Notification.Name("cmux.devices.directoryDidChange")

    private(set) var records: [DeviceDirectoryRecord] = []
    private(set) var isRunning = false
    private(set) var registryError: String?
    private(set) var hasLoadedRegistry = false
    private(set) var isRefreshingRegistry = false
    /// The revision of the v2 directory the last discovery read observed; the
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
    private let automaticClient: DeviceIrxClient?
    private var authenticatedMacs: [DeviceDiscoveredMac] = []
    private var directoryChangesTask: Task<Void, Never>?
    private let fixedSelfInstance: SurfaceDeviceInstanceID?
    private var selfInstance: SurfaceDeviceInstanceID {
        fixedSelfInstance ?? SurfaceDeviceInstanceID(deviceID: MobileHostIdentity.deviceID(), tag: MobileHostIdentity.instanceTag())
    }

    private var registryTask: Task<Void, Never>?
    private var registryGeneration: UInt64 = 0
    private var pairingObserver: NSObjectProtocol?
    init(
        identity: AuthenticatedSessionIdentity,
        teamID: String?,
        pairing: any DeviceLinkAuthorizationSource,
        automaticClient: DeviceIrxClient? = nil,
        selfInstance: SurfaceDeviceInstanceID? = nil
    ) {
        self.identity = identity
        self.teamID = teamID
        self.pairing = pairing
        self.automaticClient = automaticClient
        self.fixedSelfInstance = selfInstance
    }

    /// What a team switch carries into the next team's directory so My Devices
    /// keeps its rows while the new team's sources load. Membership is the
    /// account's (the per-user directory), so only team-scoped reads restart.
    struct CarriedState: Sendable {
        var records: [DeviceDirectoryRecord]
        var authenticatedMacs: [DeviceDiscoveredMac]
        var hasLoadedRegistry: Bool
    }

    func carriedState() -> CarriedState {
        CarriedState(records: records, authenticatedMacs: authenticatedMacs,
            hasLoadedRegistry: hasLoadedRegistry)
    }

    /// Seeds a not-yet-started directory for the same account from the
    /// previous team's directory. Ignored once started.
    func adopt(_ carried: CarriedState) {
        guard !isRunning else { return }
        records = carried.records
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
        records = []
        hasLoadedRegistry = false
        registryError = nil
        directoryStamp = nil
        notifyChanged()
    }

    /// Refresh authenticated discovery. Registry-named state remains for UI compatibility.
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
                    self.registryError = String(localized: "devices.registry.failed", defaultValue: "Could not refresh your Macs. Check your connection and try again.")
                    // An outage retains the last authenticated rows; per-session
                    // leases reject stale or revoked peers before application I/O.
                }
            } else {
                self.registryError = nil
            }
            self.hasLoadedRegistry = true
        }
        registryTask = task
        return task
    }

    private func remerge() {
        let merged = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
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
