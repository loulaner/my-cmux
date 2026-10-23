#if DEBUG && CMUX_LOCAL_TERMINAL_ACCEPTANCE && canImport(UIKit)
import CmuxMobileShell
import Foundation
import Observation
import UIKit
@testable import CmuxMobileTerminal

/// DEBUG fixture enabled only in the dedicated XCTest bundle identity. Never opens a socket or a credential file.
@MainActor @Observable
final class LocalTerminalUIAcceptance {
    static var enabled: Bool {
        Bundle.main.bundleIdentifier == "dev.cmux.ios.local-terminal-acceptance"
            && ProcessInfo.processInfo.arguments.contains("--local-terminal-ui-acceptance")
    }
    static let shared = LocalTerminalUIAcceptance()
    let controller: MobileLocalDirectClientController
    private let peer: LocalTerminalRendererRPCFixture
    private var started = false
    private(set) var status = "starting"
    private init() {
        let peer = LocalTerminalRendererRPCFixture()
        self.peer = peer
        controller = MobileLocalDirectClientController(store: peer, connect: { _, _ in peer }, admit: { _, _ in
            .init(rpc: peer, deviceID: "00000000-0000-0000-0000-000000000002", token: Data(repeating: 0, count: 32))
        })
    }
    func run() async {
        guard Self.enabled, !started else { return }
        started = true
        do {
            try await wait { UIApplication.shared.applicationState == .active }
            await controller.setForeground(true)
            controller.address = "100.64.0.2"
            await controller.pair()
            try await wait { self.controller.state == .connected }
            controller.select(workspaceID: LocalTerminalRendererRPCFixture.workspace, surfaceID: LocalTerminalRendererRPCFixture.surface)
            try await wait { self.surface != nil && self.controller.terminalSession?.state == .ready }
            guard let surface, let window = surface.window else { throw failure("surface") }
            try await peer.enterAlternate()
            try await wait { surface.renderedTextForTesting()?.contains("SYNTHETIC Pi-style menu") == true }
            _ = surface.inputProxy.becomeFirstResponder()
            try await Task.sleep(for: .seconds(1))
            try await wait { self.controller.terminalSession?.state == .ready }
            let before = await peer.viewportCount
            status = "ready-rotate"
            try await wait { window.bounds.width > window.bounds.height }
            try await wait { await self.peer.viewportCount > before && self.controller.terminalSession?.state == .ready }
            try await Task.sleep(for: .seconds(1))
            let settled = await peer.viewportCount
            try await Task.sleep(for: .seconds(2))
            guard await peer.viewportCount == settled,
                  surface.renderedTextForTesting()?.contains("SYNTHETIC Pi-style menu") == true,
                  surface.hostedAltScreenActive, !surface.isUsingSnapshotFallbackForTesting(),
                  surface.inputProxy.isFirstResponder else { throw failure("rotation-or-viewport") }
            status = "passed-landscape"
        } catch { status = "failed: \(error)" }
    }
    private var surface: GhosttySurfaceView? {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let surface = findSurface(window) { return surface }
            }
        }
        return nil
    }
    private func findSurface(_ view: UIView) -> GhosttySurfaceView? {
        if let surface = view as? GhosttySurfaceView { return surface }
        return view.subviews.lazy.compactMap { self.findSurface($0) }.first
    }
    private func wait(line: UInt = #line, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw failure("deadline line \(line), controller \(self.controller.state), session \(String(describing: self.controller.terminalSession?.state))") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private func failure(_ reason: String) -> NSError { NSError(domain: "SyntheticTerminalUI", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}
#endif
