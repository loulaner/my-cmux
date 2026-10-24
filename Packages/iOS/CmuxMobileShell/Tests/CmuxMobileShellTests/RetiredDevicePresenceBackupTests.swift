import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct RetiredDevicePresenceBackupTests {
    @Test func attachmentCapabilityRequiresExactForegroundPairing() {
        let shell = MobileShellComposite(isSignedIn: true)
        shell.foregroundMacDeviceID = "mac-a"
        shell.activeMacInstanceTag = "tag-a"
        shell.supportedHostCapabilities = [MobileShellComposite.taskAttachmentCapability]
        #expect(shell.supportsTaskAttachments(macDeviceID: "mac-a", instanceTag: "tag-a"))
        #expect(!shell.supportsTaskAttachments(macDeviceID: "mac-a", instanceTag: "tag-b"))
        #expect(!shell.supportsTaskAttachments(macDeviceID: "mac-a", instanceTag: nil))
        #expect(!shell.supportsTaskAttachments(macDeviceID: "unknown", instanceTag: "tag-a"))
        shell.supportedHostCapabilities = []
        #expect(!shell.supportsTaskAttachments(macDeviceID: "mac-a", instanceTag: "tag-a"))
    }

    @Test func attachmentCapabilityRequiresExactControlPairingWithoutDial() async throws {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()), now: { Date() }
        )
        let route = try CmxAttachRoute(id: "scripted", kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56584))
        let ticket = try CmxAttachTicket(workspaceID: "workspace", terminalID: "terminal",
            macDeviceID: "mac-b", macDisplayName: "Mac B", routes: [route], expiresAt: Date().addingTimeInterval(3600))
        let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket, allowsStackAuthFallback: true)
        let shell = MobileShellComposite(runtime: runtime, isSignedIn: true)
        let key = MacPairingKey(macDeviceID: "mac-b", instanceTag: "tag-b")
        shell.secondaryMacSubscriptions[key] = SecondaryMacSubscription(
            macDeviceID: "mac-b", client: client, route: route, ticket: ticket,
            storedInstanceTag: "tag-b", authenticatedInstanceTag: "tag-b",
            supportedHostCapabilities: [MobileShellComposite.taskAttachmentCapability],
            actionCapabilities: .none, displayName: "Mac B"
        )
        #expect(shell.supportsTaskAttachments(macDeviceID: "mac-b", instanceTag: "tag-b"))
        #expect(!shell.supportsTaskAttachments(macDeviceID: "mac-b", instanceTag: "other"))
        #expect(!shell.supportsTaskAttachments(macDeviceID: "mac-b", instanceTag: nil))
        shell.secondaryMacSubscriptions[key]?.cancel()
        shell.secondaryMacSubscriptions[key] = nil
        #expect(!shell.supportsTaskAttachments(macDeviceID: "mac-b", instanceTag: "tag-b"))
        #expect(await router.count(of: "mobile.host.status") == 0)
    }

    @Test func directoryObservationIsIdempotentAndCancelsOnScopeAndSignOut() async throws {
        let directory = LocalDirectoryObservationProbe()
        let shell = MobileShellComposite(isSignedIn: true,
            personalIrohDiscovery: directory,
            identityProvider: StaticIdentityProvider(userID: "user-1"), teamIDProvider: { "team-a" })
        shell.evaluateDirectoryObservation()
        shell.evaluateDirectoryObservation()
        #expect(try await pollUntil { directory.starts == 1 })
        shell.currentTeamDidChange()
        #expect(try await pollUntil { directory.starts == 2 && directory.stops == 1 })
        shell.signOut()
        #expect(try await pollUntil { directory.stops == 2 })
        shell.evaluateDirectoryObservation()
        #expect(directory.starts == 2)
        #expect(directory.invalidations == 0)
    }
}

@MainActor
private final class LocalDirectoryObservationProbe: MobileIrohMacDiscovering {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var invalidations = 0
    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] { [] }
    func invalidateDiscovery(forMacDeviceID _: String) async { invalidations += 1 }
    func directoryUpdates() -> AsyncStream<Void> {
        starts += 1
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stops += 1 }
            }
        }
    }
}
