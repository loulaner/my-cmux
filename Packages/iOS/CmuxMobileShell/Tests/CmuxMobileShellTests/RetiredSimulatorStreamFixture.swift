import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct RetiredSimulatorStreamFixture {
    let suite: String
    let defaults: UserDefaults
    let originalBytes: Data
    let workspace: MobileWorkspacePreview
    let browser = BrowserStreamStore()
    let router = LivenessHostRouter()
    let store: MobileShellComposite

    init(
        remembered: MobileWorkspaceLastTab = .init(kind: .simulatorStream, tabID: "sim-1"),
        hasTerminal: Bool = true,
        hasSimulatorSurface: Bool = true
    ) throws {
        suite = "RetiredSimulatorStreamTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        workspace = MobileWorkspacePreview(
            id: "workspace-1", name: "Mixed workspace",
            terminals: hasTerminal ? [MobileTerminalPreview(id: "terminal-1", name: "Shell", isFocused: true)] : [],
            surfaces: hasSimulatorSurface ? [MobileSurfacePreview(
                id: "sim-1", kind: .init(rawValue: "simulator"), title: "Simulator", isFocused: true
            )] : [],
            simulators: [MobileSimulatorPanelDescriptor(
                panelID: "sim-1", workspaceID: "workspace-1", title: "Simulator",
                selectedDeviceName: "iPhone", selectedDeviceState: "Booted",
                status: "ready", isReady: true, supportsTouch: true, supportsKeyboard: true,
                supportsHardwareButtons: true, supportsRotation: true
            )]
        )
        var memory = MobileWorkspaceLastTabStore(defaults: defaults)
        memory.set(remembered, for: workspace.lastTabStateID)
        originalBytes = try #require(defaults.data(forKey: MobileWorkspaceLastTabStore.defaultsKey))
        // Existing in-process scripted transport: no sockets, credentials or real host.
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { Date() }, supportsServerPushEvents: false
        )
        store = MobileShellComposite(
            runtime: runtime, isSignedIn: true, connectionState: .connected, workspaces: [workspace],
            clientIDRepository: MobileClientIDRepository(defaults: defaults, environment: [:]),
            pairingHintDefaults: defaults, multiMacAggregationDefaults: defaults,
            lastTabStore: memory, browserStreamEvents: browser
        )
        let route = try CmxAttachRoute(
            id: "test-only", kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 1)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-1", terminalID: "terminal-1", macDeviceID: "test-mac",
            macDisplayName: "Test Mac", routes: [route], expiresAt: Date().addingTimeInterval(3600)
        )
        store.remoteClient = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket, allowsStackAuthFallback: true)
        store.supportedHostCapabilities = ["simulator.stream.v1", "simulator.input.v1", "simulator.stream.v2"]
    }

    var persistedTab: MobileWorkspaceLastTab? {
        MobileWorkspaceLastTabStore(defaults: defaults).lastTab(for: workspace.lastTabStateID)
    }

    func expectUnchangedMemory() {
        #expect(defaults.data(forKey: MobileWorkspaceLastTabStore.defaultsKey) == originalBytes)
    }

    func expectNoSimulatorRequests() async throws {
        // Self-check the recorder on the real RPC path without contacting a host.
        let client = try #require(store.remoteClient)
        _ = try await client.sendRequest(MobileCoreRPCClient.requestData(method: "mobile.events.probe", params: [:]))
        #expect(await router.count(of: "mobile.events.probe") == 1)
        for method in ["list", "stream.start", "stream.stop", "input.pointer", "input.text",
                       "input.button", "devices.list", "device.select", "recover"] {
            #expect(await router.count(of: "mobile.simulator.\(method)") == 0)
        }
        await store.remoteClient?.disconnect()
    }

    func cleanDefaults() {
        defaults.removePersistentDomain(forName: suite)
    }
}
