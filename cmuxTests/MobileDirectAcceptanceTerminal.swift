import AppKit
import CmuxTerminal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns exactly one synthetic workspace, real PTY and window in the isolated test host.
@MainActor
final class MobileDirectAcceptanceTerminal {
    let workspace = TerminalPortalTestWorkspace()
    let panel: TerminalPanel
    let window: NSWindow
    let portal: WindowTerminalPortal
    let anchor: NSView

    init() throws {
        let id = try #require(workspace.workspace.focusedPanelId)
        panel = try #require(workspace.workspace.panels[id] as? TerminalPanel)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic local-direct terminal"
        workspace.bind(to: window)
        anchor = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 390))
        window.contentView?.addSubview(anchor)
        portal = WindowTerminalPortal(window: window)
        window.makeKeyAndOrderFront(nil)
        panel.surface.hostedView.setVisibleInUI(true)
        portal.bind(hostedView: panel.surface.hostedView, to: anchor, visibleInUI: true)
    }

    func close() {
        portal.tearDown()
        workspace.tearDown()
        window.close()
    }
}
