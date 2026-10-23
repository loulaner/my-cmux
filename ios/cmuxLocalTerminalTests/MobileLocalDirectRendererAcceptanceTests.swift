#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import GhosttyKit
import CmuxMobileSupport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileTerminal
@testable import cmuxFeature

/// Mounts the production root/representable in an actual Simulator window, with a test-only RPC peer.
@Suite(.serialized) @MainActor
struct MobileLocalDirectRendererAcceptanceTests {
    @Test func actualRootRendersScreenFramesAndRoutesInput() async throws {
        let fixture = LocalTerminalRendererRPCFixture()
        let tracker = MobileKeyboardFrameTracker()
        let controller = MobileLocalDirectClientController(store: fixture, connect: { _, _ in fixture }, admit: { _, _ in
            .init(rpc: fixture, deviceID: "00000000-0000-0000-0000-000000000002", token: Data(repeating: 0, count: 32))
        })
        await controller.setForeground(true)
        controller.address = "100.64.0.2"
        await controller.pair()
        try await wait { controller.state == .connected }
        controller.select(workspaceID: LocalTerminalRendererRPCFixture.workspace, surfaceID: LocalTerminalRendererRPCFixture.surface)
        let root = UIHostingController(rootView: MobileLocalDirectRootScene(controller: controller, keyboardFrameTracker: tracker))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: UIScreen.main.bounds) }
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { Self.findSurface(root.view) != nil }
        let surface = try #require(Self.findSurface(root.view))
        try await wait { controller.terminalSession?.state == .ready }
        #expect(surface.renderedTextForTesting()?.contains("中文宽字符") == true)
        #expect(surface.renderedTextForTesting()?.contains("FULL FRAME") == true)
        let rendered = try readFrame(surface)
        #expect(rendered.styles.contains { $0.foreground?.lowercased() == "#00ff00" })
        #expect(rendered.styles.contains { $0.foreground?.lowercased() == "#ff4444" })
        try await capture("full", surface: surface)
        try await fixture.updateDelta()
        try await wait { surface.renderedTextForTesting()?.contains("DELTA UPDATED") == true }
        #expect(surface.renderedTextForTesting()?.contains("FULL FRAME") == false)
        try await capture("delta", surface: surface)
        surface.simulateInputProxyTextChangeForTesting("中文输入", isComposing: false)
        surface.inputProxy.simulateAccessoryActionForTesting(.control)
        surface.simulateInputProxyTextChangeForTesting("c", isComposing: false)
        surface.inputProxy.simulateAccessoryActionForTesting(.escape)
        surface.inputProxy.simulateAccessoryActionForTesting(.tab)
        surface.inputProxy.simulateNubArrowForTesting(.upArrow)
        try await wait { await fixture.input == "中文输入\u{03}\u{1b}\t\u{1b}[A" }
        try await fixture.enterAlternate()
        try await wait { surface.renderedTextForTesting()?.contains("SYNTHETIC Pi-style menu") == true }
        #expect(surface.hostedAltScreenActive)
        try await capture("alternate", surface: surface)
        let beforeKeyboard = await fixture.viewportCount
        _ = surface.inputProxy.becomeFirstResponder()
        try await wait { tracker.lastEndFrame.map { $0.height > 0 && $0.minY < window.bounds.maxY } == true }
        try await wait { await fixture.viewportCount > beforeKeyboard && controller.terminalSession?.state == .ready }
        try await capture("keyboard", surface: surface)
        try #require(surface.inputProxy.isFirstResponder)
        #expect(tracker.lastEndFrame.map { $0.height > 0 && $0.minY < window.bounds.maxY } == true)
        let toolbarRect = surface.inputProxy.toolbarView.convert(surface.inputProxy.toolbarView.bounds, to: window)
        let keyboardRect = window.convert(try #require(tracker.lastEndFrame), from: window.screen.coordinateSpace)
        try #require(abs(toolbarRect.maxY - keyboardRect.minY) < 24)
        surface.resignCurrentInput()
        try await wait { controller.terminalSession?.state == .ready }
        try await Task.sleep(for: .seconds(1))
        let settled = await fixture.viewportCount
        try await Task.sleep(for: .seconds(2))
        #expect(await fixture.viewportCount == settled)
        #expect(await fixture.replayCount < 12)
        await controller.disconnect()
        #expect(controller.terminalSession == nil)
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "DirectRendererAcceptanceTimeout", code: Int(line), userInfo: [NSLocalizedDescriptionKey: "Timed out at \(file):\(line)"]) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private static func findSurface(_ view: UIView) -> GhosttySurfaceView? {
        if let surface = view as? GhosttySurfaceView { return surface }
        return view.subviews.lazy.compactMap { findSurface($0) }.first
    }
    private func readFrame(_ view: GhosttySurfaceView) throws -> MobileTerminalRenderGridFrame {
        let surface = try #require(view.surface)
        let identifier = LocalTerminalRendererRPCFixture.surface
        let exported = identifier.withCString {
            ghostty_surface_render_grid_json_with_theme(surface, $0, UInt(identifier.utf8.count), 1, 0, true)
        }
        defer { ghostty_string_free(exported) }
        let pointer = try #require(exported.ptr)
        return try JSONDecoder().decode(MobileTerminalRenderGridFrame.self,
                                        from: Data(bytes: pointer, count: Int(exported.len)))
    }

    private func capture(_ name: String, surface: GhosttySurfaceView) async throws {
        #expect(!surface.isUsingSnapshotFallbackForTesting())
        // External simctl captures the composited Simulator screen during this bounded pause.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-local-terminal-acceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((surface.renderedTextForTesting() ?? "").utf8).write(to: directory.appendingPathComponent(name + ".txt"))
        try Data(name.utf8).write(to: directory.appendingPathComponent("capture-ready"), options: .atomic)
        try await Task.sleep(for: .seconds(5))
    }
}
#endif
