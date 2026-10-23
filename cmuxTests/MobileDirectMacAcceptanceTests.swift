import AppKit
import SwiftUI
import CMUXMobileCore
import CMUXAuthCore
import CmuxAuthRuntime
import CmuxSettings
import CmuxTerminal
@testable import CmuxMobileTransport
import Foundation
import Observation
import Testing
import os
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor @Suite(.serialized)
struct MobileDirectMacAcceptanceTests {
    private var evidenceDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CMUX_DIRECT_ACCEPTANCE_DIR"]!)
    }
    private func requireIsolation() throws {
        #expect(Bundle.main.bundleIdentifier == "com.cmuxterm.app.debug.local-terminal-acceptance")
        let env = ProcessInfo.processInfo.environment
        let home = try #require(env["CMUX_LOCAL_ACCEPTANCE_HOME"])
        try #require(home.hasPrefix("/private/tmp/"))
        #expect(env["HOME"] == home && env["CFFIXED_USER_HOME"] == home)
        #expect(env["XDG_CONFIG_HOME"] == home + "/.config")
        #expect(Data(base64Encoded: env["CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64"] ?? "")?.count == 32)
        #expect(TestProcessDefaults.isolatedDomainName != nil)
    }
    private func controller(_ name: String, policy: @escaping @Sendable () -> Bool = { false }) throws -> MobileLocalDirectHostController {
        try MobileLocalDirectHostController(baseURL: evidenceDirectory.appendingPathComponent(name), policyDisabled: policy,
            listenerFactory: { _, handler in CmxLocalTCPListener(configuration: .loopbackForTesting(), onUnauthenticatedConnection: handler) })
    }
    private func connect(_ controller: MobileLocalDirectHostController) async throws -> CmxNetworkByteTransport {
        guard case let .listening(address, port) = controller.state else { throw CmxLocalDirectAdmission.Failure.denied }
        let stream = try CmxNetworkByteTransport(host: address, port: port)
        try await stream.connect()
        return stream
    }
    private func pair(_ controller: MobileLocalDirectHostController) async throws -> CmxLocalDirectAdmission.ClientAccepted {
        let stream = try await connect(controller)
        var request: Task<CmxLocalDirectAdmission.ClientAccepted, any Error>!
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = controller.pendingApproval } onChange: { continuation.resume() }
            request = Task { try await CmxLocalDirectAdmission.pair(displayName: "Synthetic tablet", transport: stream) }
        }
        controller.resolveApproval(true)
        return try await request.value
    }
    private func rpc(_ stream: any CmxByteTransport, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await stream.send(MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject:
            ["id": "acceptance", "method": method, "params": params])))
        var buffer = Data()
        while let chunk = try await stream.receive() {
            buffer.append(chunk)
            if let frame = try MobileSyncFrameCodec.decodeFrames(from: &buffer, maximumDecodedFrameCount: 1).first {
                let object = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
                try #require(object["ok"] as? Bool == true, "RPC must succeed")
                return try #require(object["result"] as? [String: Any])
            }
        }
        throw CmxLocalDirectAdmission.Failure.denied
    }



    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_DIRECT_ACCEPTANCE_DIR"] != nil), .timeLimit(.minutes(1)))
    func retiredMobileRuntimeCannotActivateButDirectCan() async throws {
        try requireIsolation()
        let defaults = UserDefaults.standard
        let keys = [MobileHostService.listeningEnabledDefaultsKey,
            DevicesCatalogSection().discoveryEnabled.userDefaultsKey,
            DevicesCatalogSection().incomingAccessEnabled.userDefaultsKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        for signedIn in [false, true] {
            let suite = "RetiredMobileRuntime.\(UUID())"
            let authDefaults = try #require(UserDefaults(suiteName: suite))
            defer { authDefaults.removePersistentDomain(forName: suite) }
            let auth = AuthCoordinator(client: TeamChangeAuthClient(),
                sessionCache: CMUXAuthSessionCache(keyValueStore: authDefaults, key: "session"),
                userCache: CMUXAuthIdentityStore(keyValueStore: authDefaults, key: "user"),
                teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: authDefaults, key: "team"),
                anchor: AuthPresentationContextProvider(),
                config: AuthConfig(stack: CMUXAuthConfig(projectId: "fixture", publishableClientKey: "fixture"),
                    magicLinkCallbackURL: "http://127.0.0.1:1/callback", apiBaseURL: "http://127.0.0.1:1"),
                launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false,
                    environment: signedIn ? ["CMUX_UITEST_AUTH_FIXTURE": "1", "CMUX_UITEST_AUTH_USER_ID": "fixture",
                        "CMUX_UITEST_AUTH_FIXTURE_TEAMS": "1"] : [:], includesDevAuth: true))
            if signedIn {
                auth.start()
                await auth.awaitBootstrapped()
            }
            try #require(auth.isAuthenticated == signedIn)
            try #require((auth.authenticatedTeamScope != nil) == signedIn)
            for mask in 0..<8 {
                for (index, key) in keys.enumerated() { defaults.set(mask & (1 << index) != 0, forKey: key) }
                var preferenceReads = 0
                let runtime = MobileHostIrxRuntime(managedDevicePolicy: ManagedDevicePolicy(
                    releaseDomainDefaults: nil, forcedObject: { _, _ in nil }), pairingEnabled: {
                        preferenceReads += 1
                        return mask & 1 != 0
                    })
                // Fail before configuring the old owner: red must not open native sockets or Keychain.
                try #require(!runtime.isNetworkingAllowed)
                #expect(preferenceReads == 0, "Retirement is unconditional, not an opt-in setting")
                runtime.configure(auth: auth)
                #expect(runtime.auth == nil, "Retired owner must not retain auth or install scope observers")
                await runtime.applyManagedNetworkingPolicy()
                await runtime.foreground()
                await runtime.restartForConfigurationChange()
                #expect(!runtime.isNetworkingAllowed)
                #expect(runtime.listenerState.phase == .stopped)
                #expect(runtime.controlService == nil && runtime.endpointSupervisor == nil)
                #expect(runtime.settingsPhase == .idle)
                #expect(await runtime.irohSettingsSnapshot().runtimeStatus == .inactive)
                if let identity = auth.authenticatedSessionIdentity {
                    #expect(runtime.makeDeviceClient(identity: identity, teamID: auth.resolvedTeamID) == nil)
                }
                await runtime.stopHost()
            }
        }
        let status = await MobileHostService.shared.ensureListeningAndReady()
        #expect(!status.isRunning && status.routes.isEmpty)
        let direct = try controller("retirement-direct")
        await direct.load()
        await direct.apply(address: "100.70.1.2", port: "49443", enabled: true)
        if case .listening = direct.state {} else { Issue.record("Explicit direct listener did not start") }
        await direct.stop()
        #expect(direct.state == .stopped)
        try "16 auth/preference combinations stopped; no auth retained, control service or endpoint; explicit isolated direct listener starts/stops\n"
            .write(to: evidenceDirectory.appendingPathComponent("retirement.receipt"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_DIRECT_ACCEPTANCE_DIR"] != nil), .timeLimit(.minutes(1)))
    func isolatedActualViewBitmaps() async throws {
        try requireIsolation()
        let host = try controller("view-render-only")
        await host.load()
        await host.apply(address: "", port: "49443", enabled: false)
        try #require(host.configuration?.address == nil && host.state == .stopped)
        var receipts: [String] = []
        receipts.append(try renderView(host, size: NSSize(width: 560, height: 680), name: "view-default-off"))
        await host.apply(address: "100.70.1.2", port: "49443", enabled: false)
        try #require(host.state == .stopped && host.configuration?.enabled == false)
        receipts.append(try renderView(host, size: NSSize(width: 560, height: 680), name: "view-configured-off"))
        receipts.append(try renderView(host, size: NSSize(width: 480, height: 420), name: "view-narrow"))
        await host.stop()
        try receipts.joined(separator: "\n").write(to: evidenceDirectory.appendingPathComponent("view-render.receipt"),
            atomically: true, encoding: .utf8)
    }

    private func renderView(_ controller: MobileLocalDirectHostController, size: NSSize, name: String) throws -> String {
        let root = MobileLocalDirectView(controller: controller)
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: evidenceDirectory.appendingPathComponent(name + ".png"), options: .atomic)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        #expect(hosting.bounds.size == size)
        let visibleFields = descendants(hosting).compactMap { $0 as? NSTextField }.filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
        var outside = 0
        for field in visibleFields {
            let rectangle = field.convert(field.bounds, to: hosting)
            if !hosting.bounds.insetBy(dx: -1, dy: -1).contains(rectangle) { outside += 1 }
        }
        #expect(outside == 0, "Editable field extends outside the supplied viewport")
        return "\(name): points=\(Int(size.width))x\(Int(size.height)) pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) bytes=\(bytes.count) editableFields=\(visibleFields.count) outOfViewportFields=\(outside); view bitmap only, not compositor/focus/click evidence"
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_DIRECT_ACCEPTANCE_DIR"] != nil), .timeLimit(.minutes(1)))
    func actualPairingWindowAndPanelScreenshots() async throws {
        try requireIsolation()
        let host = MobileLocalDirectHostController.shared
        await host.load()
        try #require(host.configuration?.enabled == false)
        #expect(host.configuration?.address == nil && host.state == .stopped)
        MobilePairingWindowController.shared.show()
        let window = try #require(MobilePairingWindowController.shared.window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await capture(window, name: "pairing-default")
        let fields = descendants(try #require(window.contentView)).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let address = try #require(fields.first { $0.stringValue.isEmpty })
        address.stringValue = "not-an-ip"
        address.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: address))
        window.contentView?.layoutSubtreeIfNeeded()
        try await capture(window, name: "pairing-invalid")
        #expect(host.configuration?.enabled == false && host.configuration?.address == nil)
        window.setContentSize(NSSize(width: 480, height: 420))
        window.contentView?.layoutSubtreeIfNeeded()
        try await capture(window, name: "pairing-resized")

        let fixture = TerminalPortalTestWorkspace()
        defer { fixture.tearDown() }
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panelWindow.isReleasedWhenClosed = false
        defer { panelWindow.close() }
        fixture.bind(to: panelWindow)
        let app = try #require(AppDelegate.shared)
        let identifier = try #require(panelWindow.identifier?.rawValue)
        let windowID = try #require(UUID(uuidString: String(identifier.dropFirst("cmux.main.".count))))
        let manager = try #require(app.tabManagerFor(windowId: windowID))
        let workspace = try #require(app.performMobileConnectWorkspaceAction(tabManager: manager,
            preferredWindow: panelWindow, focusWorkspace: true, bringWindowForward: false))
        #expect(workspace.panels.values.contains { $0 is MobilePairingPanel })
        // Render the actual panel view selected by the standard workspace action.
        // This image is panel-content evidence, not a claim about the full sidebar chrome.
        panelWindow.contentViewController = NSHostingController(rootView: MobilePairingPanelView(
            appearance: PanelAppearance.fromConfig(GhosttyConfig.loadForCmux()), onRequestPanelFocus: {}))
        panelWindow.makeKeyAndOrderFront(nil)
        panelWindow.contentView?.layoutSubtreeIfNeeded()
        try await capture(panelWindow, name: "pairing-panel-content")
        #expect(host.configuration?.enabled == false && !host.allowsPairing)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func capture(_ window: NSWindow, name: String) async throws {
        // Same own-process/window-restricted capture backend used by cmux shot.
        do {
            let frame = try await OwnWindowFrameCapture(windowID: UInt32(window.windowNumber)).captureOnce()
            _ = try WindowStillImageWriter.write(frame.image, to: evidenceDirectory.appendingPathComponent(name + ".png"),
                format: .png, quality: 0.9)
        } catch {
            // Preserve the capture failure and continue independent UI checks;
            // do not fall back to a wider capture API or fabricate a screenshot.
            let detail = "pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber) visible=\(window.isVisible) size=\(window.frame.size) error=\(error)\n"
            try detail.write(to: evidenceDirectory.appendingPathComponent(name + "-capture-failure.log"), atomically: true, encoding: .utf8)
            Issue.record("Own-window capture unavailable for \(name): \(error)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_DIRECT_ACCEPTANCE_DIR"] != nil), .timeLimit(.minutes(1)))
    func realPTYSurvivesReconnectAndRevocation() async throws {
        try requireIsolation()
        let target = try MobileDirectAcceptanceTerminal()
        defer { target.close() }
        let other = try MobileDirectAcceptanceTerminal()
        defer { other.close() }
        let host = try controller("pty-host")
        defer { Task { await host.stop() } }
        await host.load()
        await host.apply(address: "100.70.1.2", port: "49443", enabled: true)
        let view = UUID()
        host.viewOpened(view); host.openPairingWindow()
        let first = try await pair(host)
        let token = try #require(first.issuedToken)
        let listing = try await rpc(first.transport, "workspace.list")
        let workspaces = try #require(listing["workspaces"] as? [[String: Any]])
        let listed = try #require(workspaces.first { $0["id"] as? String == target.workspace.id.uuidString })
        let terminals = try #require(listed["terminals"] as? [[String: Any]])
        let terminal = try #require(terminals.first { $0["id"] as? String == target.panel.id.uuidString })
        let surfaceID = try #require(terminal["id"] as? String)
        let params: [String: Any] = ["workspace_id": target.workspace.id.uuidString, "surface_id": surfaceID]
        _ = try await rpc(first.transport, "mobile.terminal.replay", params)
        let tty = try #require(target.panel.surface.controllingTTYName())
        let marker1 = "CMUX_DIRECT_A_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await inputAndObserve(first.transport, params: params, marker: marker1)
        await first.transport.close()
        #expect(target.panel.surface.controllingTTYName() == tty)
        let raw = try await connect(host)
        let second = try await CmxLocalDirectAdmission.authenticate(deviceID: first.deviceID, token: token, transport: raw)
        _ = try await rpc(second.transport, "mobile.terminal.replay", params)
        let marker2 = "CMUX_DIRECT_B_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await inputAndObserve(second.transport, params: params, marker: marker2)
        #expect(target.panel.surface.controllingTTYName() == tty)
        let otherReplay = try await rpc(second.transport, "mobile.terminal.replay",
            ["workspace_id": other.workspace.id.uuidString, "surface_id": other.panel.id.uuidString])
        let otherText = try replayText(otherReplay)
        #expect(!otherText.contains(marker1) && !otherText.contains(marker2))
        await host.removeDevice(first.deviceID)
        #expect(try await second.transport.receive() == nil)
        let revoked = try await connect(host)
        await #expect(throws: CmxLocalDirectAdmission.Failure.self) {
            try await CmxLocalDirectAdmission.authenticate(deviceID: first.deviceID, token: token, transport: revoked)
        }
        #expect(target.panel.surface.controllingTTYName() == tty)
        await second.transport.close()
        await host.stop(); host.viewClosed(view)
        try "real PTY marker A/B via RPC; same terminal ID and TTY; unrelated terminal unchanged; revoke disconnected idle and refused old token\n"
            .write(to: evidenceDirectory.appendingPathComponent("pty.receipt"), atomically: true, encoding: .utf8)
    }
    private func replayText(_ object: [String: Any]) throws -> String {
        let grid = try #require(object["render_grid"] as? [String: Any])
        let frame = try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: JSONSerialization.data(withJSONObject: grid))
        return frame.plainRows().joined(separator: "\n")
    }
    private func inputAndObserve(_ stream: any CmxByteTransport, params: [String: Any], marker: String) async throws {
        var input = params
        let encoded = marker.utf8.map { String(format: "\\%03o", $0) }.joined()
        input["text"] = "printf '\(encoded)\\012'\r"
        _ = try await rpc(stream, "mobile.terminal.input", input)
        let deadline = ContinuousClock.now + .seconds(8)
        repeat {
            // Each iteration is an actual replay transaction; no fabricated PTY output or sleep.
            if try replayText(await rpc(stream, "mobile.terminal.replay", params)).contains(marker) { return }
        } while ContinuousClock.now < deadline && !Task.isCancelled
        Issue.record("Expected printf output in server replay, not echoed input")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_DIRECT_ACCEPTANCE_DIR"] != nil), .timeLimit(.minutes(1)))
    func dynamicMDMClosesPendingAndIdleSession() async throws {
        try requireIsolation()
        // Synchronous injected MDM accessor; lock protects only this test flag.
        let disabled = OSAllocatedUnfairLock(initialState: false)
        let host = try controller("mdm-host", policy: { disabled.withLock { $0 } })
        defer { Task { await host.stop() } }
        await host.load(); await host.apply(address: "100.70.1.2", port: "49443", enabled: true)
        let view = UUID(); host.viewOpened(view); host.openPairingWindow()
        let admitted = try await pair(host)
        _ = try await rpc(admitted.transport, "mobile.host.status")
        var pending: Task<Bool, Never>!
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = host.pendingApproval } onChange: { continuation.resume() }
            pending = Task { await host.requestApproval("Second synthetic tablet") }
        }
        disabled.withLock { $0 = true }
        NotificationCenter.default.post(name: ManagedDevicePolicy.didChangeNotification, object: nil)
        #expect(!(await pending.value))
        #expect(host.state == .stopped)
        #expect(try await admitted.transport.receive() == nil)
        #expect(host.registry.count == 0)
        await host.stop(); host.viewClosed(view)
        try "injected policy + notification stopped listener, denied pending approval and disconnected idle session\n"
            .write(to: evidenceDirectory.appendingPathComponent("mdm.receipt"), atomically: true, encoding: .utf8)
    }
}
