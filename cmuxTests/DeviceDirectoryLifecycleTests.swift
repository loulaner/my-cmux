import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrxTransport
import CmuxMobileRPC
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Devices: authenticated directory lifecycle", .timeLimit(.minutes(5)))
struct DeviceDirectoryLifecycleTests {
    @Test("My Devices never falls back to pairing without authenticated opt-in", arguments: [false, true], [false, true])
    func undiscoverablePairingStaysHidden(savedPairing: Bool, hasDiscoveryClient: Bool) async throws {
        let suite = "DeviceDirectoryOptIn-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = SurfaceDeviceInstanceID(deviceID: "peer", tag: "test")
        let pairing = UnpairedDevices()
        if savedPairing {
            pairing.pairedDevices = [.init(instance: peer, displayName: "Studio", routes: [], lastSeenAt: nil)]
        }
        let automaticClient = DeviceIrxClient(context: { throw DeviceLinkError.notConnected },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "discovery-opt-in"))
        let directory = makeDirectory(defaults: defaults,
            pairing: pairing, automaticClient: hasDiscoveryClient ? automaticClient : nil)
        defer { directory.stop() }
        await directory.refreshRegistry().value
        #expect(directory.records.isEmpty, "An unavailable authenticated directory must not fall back to pairing")
    }

    @Test("Starting twice installs one pairing observer and one refresh; stopping permits restart")
    func startIsIdempotentAndStopAllowsRegistryRestart() async throws {
        let suite = "DeviceDirectoryStart-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pairing = UnpairedDevices()
        let directory = makeDirectory(defaults: defaults, pairing: pairing)
        defer { directory.stop() }
        // With no discovery client, start exercises lifecycle without a pushed initial refresh.
        directory.start()
        let firstTask = directory.refreshRegistry()
        let reads = pairing.readCount
        directory.start()
        #expect(directory.isRunning)
        #expect(pairing.readCount == reads)
        NotificationCenter.default.post(name: pairing.authorizationDidChangeNotification, object: nil)
        #expect(pairing.readCount == reads + 1, "Only one pairing observer should remerge")
        await firstTask.value
        #expect(directory.hasLoadedRegistry && !directory.isRefreshingRegistry)
        #expect(directory.registryError == nil, "No discovery client completes without a network substitute")
        directory.start()
        #expect(!directory.isRefreshingRegistry, "A second start must not launch another registry read")
        directory.stop()
        #expect(!directory.isRunning && !directory.hasLoadedRegistry)
        let stoppedReads = pairing.readCount
        NotificationCenter.default.post(name: pairing.authorizationDidChangeNotification, object: nil)
        #expect(pairing.readCount == stoppedReads, "Stop removes the observer")
        directory.start()
        let restartedTask = directory.refreshRegistry()
        await restartedTask.value
        #expect(directory.isRunning && directory.hasLoadedRegistry && !directory.isRefreshingRegistry)
    }

    @Test("An empty directory publishes actual start and stop transitions")
    func emptyDirectoryPublishesLifecycle() throws {
        let suite = "DeviceDirectoryEmpty-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = makeDirectory(defaults: defaults)
        let recorded = LifecycleRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: DeviceDirectory.didChangeNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard notification.object as? DeviceDirectory === directory else { return }
                if recorded.states.last != directory.isRunning { recorded.states.append(directory.isRunning) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer); directory.stop() }
        directory.start()
        directory.start()
        directory.stop()
        #expect(directory.records.isEmpty)
        #expect(recorded.states == [true, false])
    }

    private final class LifecycleRecorder {
        var states: [Bool] = []
    }

    @Test("A cancelled registry read cannot publish over its replacement", .timeLimit(.minutes(5)))
    func cancelledRegistryReadCannotPublish() async throws {
        let suite = "DeviceDirectoryRegistry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = AsyncStream<CheckedContinuation<DeviceIrxClientContext, any Error>>.makeStream()
        defer { requests.continuation.finish() }
        let client = DeviceIrxClient(context: {
            try await withCheckedThrowingContinuation { requests.continuation.yield($0) }
        }, journal: IrxJournal(subsystem: "dev.cmux.tests", category: "directory-cancellation"))
        let directory = makeDirectory(
            defaults: defaults, automaticClient: client
        )
        defer { directory.stop() }
        var calls = requests.stream.makeAsyncIterator()
        let oldTask = directory.refreshRegistry()
        let oldRequest = try #require(await calls.next())
        directory.stop()
        let newTask = directory.refreshRegistry()
        let newRequest = try #require(await calls.next())
        oldRequest.resume(throwing: DeviceLinkError.notConnected)
        await oldTask.value
        #expect(directory.isRefreshingRegistry)
        #expect(!directory.hasLoadedRegistry)
        #expect(directory.registryError == nil)
        newRequest.resume(throwing: DeviceLinkError.notConnected)
        await newTask.value
        #expect(!directory.isRefreshingRegistry)
        #expect(directory.hasLoadedRegistry)
        #expect(directory.registryError != nil)
    }

    @Test("Cancelling the current registry refresh releases its busy state", .timeLimit(.minutes(5)))
    func cancelledCurrentRegistryReadCanRetry() async throws {
        let suite = "DeviceDirectoryCancel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = AsyncStream<CheckedContinuation<DeviceIrxClientContext, any Error>>.makeStream()
        defer { requests.continuation.finish() }
        let client = DeviceIrxClient(context: {
            try await withCheckedThrowingContinuation { requests.continuation.yield($0) }
        }, journal: IrxJournal(subsystem: "dev.cmux.tests", category: "directory-cancellation"))
        let directory = makeDirectory(
            defaults: defaults, automaticClient: client
        )
        defer { directory.stop() }
        var calls = requests.stream.makeAsyncIterator()
        let task = directory.refreshRegistry()
        let request = try #require(await calls.next())
        task.cancel()
        request.resume(throwing: CancellationError())
        await task.value
        #expect(!directory.isRefreshingRegistry)
        #expect(!directory.hasLoadedRegistry)
        let retry = directory.refreshRegistry()
        let retriedRequest = try #require(await calls.next())
        retriedRequest.resume(throwing: DeviceLinkError.notConnected)
        await retry.value
        #expect(directory.hasLoadedRegistry)
        #expect(!directory.isRefreshingRegistry)
        #expect(directory.registryError != nil)
    }

    @Test("Discovery failure reports the existing error without dropping authenticated rows")
    func discoveryFailureRetainsAuthenticatedRows() async throws {
        let suite = "DeviceDirectoryFailure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = DeviceIrxClient(context: { throw DeviceLinkError.notConnected },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "discovery-failure"))
        let peer = DeviceDiscoveredMac(bindingID: "binding-peer", deviceID: "peer", tag: "test",
            displayName: "Peer", endpointID: try CmxIrohPeerIdentity(endpointID: String(repeating: "b", count: 64)),
            pathHints: [], controlPlaneSupportsMacPeers: true)
        let previous = DeviceDirectoryMerge.merge(.init(authenticatedMacs: [peer],
            requiresAuthenticatedDiscovery: true, selfInstance: SurfaceDeviceInstanceID(deviceID: "self", tag: "test")))
        let directory = makeDirectory(defaults: defaults, automaticClient: client)
        defer { directory.stop() }
        directory.adopt(.init(records: previous, authenticatedMacs: [peer], hasLoadedRegistry: true))
        await directory.refreshRegistry().value
        #expect(directory.records == previous)
        #expect(directory.records.count == 1)
        #expect(directory.registryError == String(localized: "devices.registry.failed", defaultValue: "Could not refresh your Macs. Check your connection and try again."))
        #expect(directory.hasLoadedRegistry && !directory.isRefreshingRegistry)
    }

    @Test("Carried registry, previous rows, and pairings cannot admit a Mac without authenticated discovery")
    func carriedLegacySourcesCannotAdmitUndiscoverablePeers() async throws {
        let suite = "DeviceDirectoryAdmission-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = SurfaceDeviceInstanceID(deviceID: "peer", tag: "test")
        let pairing = UnpairedDevices()
        pairing.pairedDevices = [.init(instance: peer, displayName: "Peer", routes: [], lastSeenAt: nil)]
        let registered = DeviceRegistryDirectoryWire.Device(deviceID: peer.deviceID, platform: "mac",
            displayName: "Peer", isManual: false, lastSeenAt: nil,
            instances: [.init(tag: peer.tag, routes: [], lastSeenAt: nil)])
        let previous = DeviceDirectoryMerge.merge(.init(registry: [registered], paired: pairing.pairedDevices,
            selfInstance: SurfaceDeviceInstanceID(deviceID: "self", tag: "test")))
        #expect(previous.count == 1, "The legacy fixture must contain a candidate")
        let directory = makeDirectory(defaults: defaults, pairing: pairing)
        defer { directory.stop() }
        directory.adopt(.init(records: previous, authenticatedMacs: [], hasLoadedRegistry: true))
        directory.start()
        #expect(directory.records.isEmpty, "Starting remerges under authenticated-only admission")
        await directory.refreshRegistry().value
        #expect(directory.records.isEmpty, "Registry enrichment must not restore an unauthorized peer")
    }

    /// A registry over one discovered Mac whose session scope the test drives.
    private final class TeamSwitchHarness {
        var identity: AuthenticatedSessionIdentity? = AuthenticatedSessionIdentity(generation: 1, accountID: "test")
        var teamID: String? = "team-a"
        var directories: [DeviceDirectory] = []
        var retainsAcrossTeamChanges = true
    }

    private func makeTeamSwitchRegistry(defaults: UserDefaults, clock: SidebarTestManualClock,
                                        harness: TeamSwitchHarness) -> DeviceSurfaceProviderRegistry {
        let peer = DeviceDiscoveredMac(bindingID: "binding-peer", deviceID: "peer", tag: "test",
            displayName: "Peer", endpointID: try! CmxIrohPeerIdentity(endpointID: String(repeating: "b", count: 64)),
            pathHints: [], controlPlaneSupportsMacPeers: true)
        return DeviceSurfaceProviderRegistry(
            notificationCenter: NotificationCenter(),
            sessionScope: { _ in (harness.identity, harness.teamID) },
            allowsAutomaticConnections: { true },
            retainsAcrossTeamChanges: { harness.retainsAcrossTeamChanges },
            makeDirectory: { _, _, teamID, _, client in
                let directory = makeDirectory(defaults: defaults, teamID: teamID,
                    automaticClient: client)
                // Every directory starts out having discovered the peer once,
                // standing in for the account directory's authenticated read.
                directory.adopt(DeviceDirectory.CarriedState(records: [],
                    authenticatedMacs: [peer], hasLoadedRegistry: true))
                harness.directories.append(directory)
                return directory
            },
            isFeatureEnabled: { true }
        )
    }

    @Test("A team switch keeps every My Devices row, provider, and directory")
    func teamSwitchKeepsRows() async throws {
        let suite = "DevicesTeamSwitch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SidebarTestManualClock()
        let harness = TeamSwitchHarness()
        let registry = makeTeamSwitchRegistry(defaults: defaults, clock: clock, harness: harness)
        let catalog = SurfaceCatalog()
        registry.configure(auth: makeAuth(defaults: defaults), catalog: catalog, authorization: UnpairedDevices())
        let instance = SurfaceDeviceInstanceID(deviceID: "peer", tag: "test")
        let provider = try #require(registry.provider(for: instance))
        let directoryBefore = try #require(registry.directory)
        let rowsBefore = registry.directory?.records ?? []
        #expect(!rowsBefore.isEmpty)

        harness.teamID = "team-b"
        registry.evaluate()

        // Same provider object, still registered, rows visible at once.
        #expect(registry.provider(for: instance) === provider)
        #expect(registry.providerCount == 1)
        #expect(registry.directory?.records == rowsBefore)
        #expect(registry.directory?.hasLoadedRegistry == true)
        #expect(harness.directories.count == 1)
        #expect(registry.directory === directoryBefore)
        harness.identity = nil
        registry.evaluate()
        await clock.waitUntilIdle()
    }

    @Test("When the account directory is off, a team switch rebuilds its team scope")
    func teamSwitchRebuildsWithoutAccountDirectory() async throws {
        let suite = "DevicesTeamSwitchOff-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SidebarTestManualClock()
        let harness = TeamSwitchHarness()
        harness.retainsAcrossTeamChanges = false
        let registry = makeTeamSwitchRegistry(defaults: defaults, clock: clock, harness: harness)
        registry.configure(auth: makeAuth(defaults: defaults), catalog: SurfaceCatalog(), authorization: UnpairedDevices())
        let instance = SurfaceDeviceInstanceID(deviceID: "peer", tag: "test")
        let provider = try #require(registry.provider(for: instance))

        harness.teamID = "team-b"
        registry.evaluate()

        #expect(registry.provider(for: instance) !== provider)
        #expect(harness.directories.count == 2)
        harness.identity = nil
        registry.evaluate()
        await clock.waitUntilIdle()
    }

    @Test("An account switch or sign-out still clears every row and provider")
    func accountSwitchClearsRows() async throws {
        let suite = "DevicesAccountSwitch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SidebarTestManualClock()
        let harness = TeamSwitchHarness()
        let registry = makeTeamSwitchRegistry(defaults: defaults, clock: clock, harness: harness)
        registry.configure(auth: makeAuth(defaults: defaults), catalog: SurfaceCatalog(), authorization: UnpairedDevices())
        let instance = SurfaceDeviceInstanceID(deviceID: "peer", tag: "test")
        let provider = try #require(registry.provider(for: instance))

        harness.identity = AuthenticatedSessionIdentity(generation: 2, accountID: "test")
        registry.evaluate()
        // A rebuild: the old provider is gone and a new one serves the row.
        #expect(registry.provider(for: instance) !== provider)
        #expect(harness.directories.count == 2)

        harness.identity = nil
        registry.evaluate()
        #expect(registry.directory == nil)
        #expect(registry.providerCount == 0)
        await clock.waitUntilIdle()
    }

    private func makeDirectory(
        defaults: UserDefaults,
        teamID: String? = nil,
        pairing: (any DeviceLinkAuthorizationSource)? = nil,
        automaticClient: DeviceIrxClient? = nil
    ) -> DeviceDirectory {
        return DeviceDirectory(
            identity: AuthenticatedSessionIdentity(generation: 0, accountID: "test"),
            teamID: teamID, pairing: pairing ?? UnpairedDevices(),
            automaticClient: automaticClient,
            selfInstance: SurfaceDeviceInstanceID(deviceID: "self", tag: "test")
        )
    }

    private func makeAuth(defaults: UserDefaults) -> AuthCoordinator {
        let config = AuthConfig(
            stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
            magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback",
            apiBaseURL: "http://127.0.0.1:1"
        )
        return AuthCoordinator(
            client: StackAuthClient(config: config, tokenStore: .memory, noAutomaticPrefetch: true),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(), config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: [:], includesDevAuth: false)
        )
    }

    @Test("Cloud availability stops directory work and re-enables it once without an open sidebar")
    func cloudGateOwnsRegistryLifetime() async throws {
        let suite = "DevicesRegistryGate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        let clock = SidebarTestManualClock()
        var enabled = false
        var directoryCreations = 0
        var transportCreations = 0
        let registry = DeviceSurfaceProviderRegistry(
            notificationCenter: center,
            sessionScope: { _ in (AuthenticatedSessionIdentity(generation: 1, accountID: "test"), "team") },
            makeAutomaticClient: { _, _ in transportCreations += 1; return nil },
            allowsAutomaticConnections: { true },
            makeDirectory: { _, _, _, _, _ in
                directoryCreations += 1
                return makeDirectory(defaults: defaults)
            },
            isFeatureEnabled: { enabled }
        )
        registry.configure(auth: makeAuth(defaults: defaults), catalog: SurfaceCatalog(), authorization: UnpairedDevices())
        #expect(!registry.isRunning)
        #expect(directoryCreations == 0 && transportCreations == 0)
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(registry.isRunning)
        #expect(directoryCreations == 1 && transportCreations == 1)
        enabled = false
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        await registry.refresh(force: true)
        #expect(!registry.isRunning && registry.directory == nil && registry.providerCount == 0)
        #expect(directoryCreations == 1 && transportCreations == 1)
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(registry.isRunning)
        #expect(directoryCreations == 2 && transportCreations == 2)
        enabled = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        await clock.waitUntilIdle()
    }

    private final class UnpairedDevices: DeviceLinkAuthorizationSource {
        private var savedDevices: [DevicePairedDevice] = []
        private(set) var readCount = 0
        var pairedDevices: [DevicePairedDevice] {
            get { readCount += 1; return savedDevices }
            set { savedDevices = newValue }
        }
        let authorizationDidChangeNotification = Notification.Name("DeviceDirectoryLifecycle-\(UUID().uuidString)")
        func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? { nil }
    }
}
