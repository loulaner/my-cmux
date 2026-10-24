import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The RPC pairing deadline cancels a wedged in-flight iroh dial, so the
/// transport pool observes only a cancellation and cannot classify the route
/// failure. The shell owner that classified the timeout must therefore report
/// the staleness itself, so the NEXT reconnect attempt rebuilds its dial plan
/// from a fresh broker snapshot instead of burning backoff on a corpse route.
@MainActor
@Suite struct RouteFailureDiscoveryInvalidationTests {
    @Test func timedOutIrohRouteDialInvalidatesDiscoveryForNextAttempt() async throws {
        let discovery = RecordingIrohDiscovery()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let irohRoute = try CmxAttachRoute(
            id: "iroh-personal",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: -10_000
        )
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [irohRoute],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date()
        )
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        // An iroh dial that neither completes nor fails: the pairing request
        // deadline is the only thing that can settle this attempt.
        factory.setHangingKinds([.iroh])
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { Date() },
                supportedRouteKinds: [.iroh],
                pairingRequestTimeoutNanoseconds: 50_000_000,
                pairingAttemptTimeoutNanoseconds: 200_000_000
            ),
            isSignedIn: true,
            pairedMacStore: pairedStore,
            personalIrohDiscovery: discovery,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "route-failure-invalidation-\(UUID().uuidString)"
            )!,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))

        #expect(discovery.invalidatedDeviceIDs.contains("test-mac"))
        await factory.releaseHangingTransports()
    }
}

@MainActor
private final class RecordingIrohDiscovery: MobileIrohMacDiscovering {
    private(set) var invalidatedDeviceIDs: [String] = []

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] { [] }

    func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        invalidatedDeviceIDs.append(deviceID)
    }
}
