#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// UIKit/Ghostty adapter for a direct session. The caller owns the app-lifetime keyboard tracker.
/// Uses terminal-only controls without altering shared toolbar settings.
@MainActor
public struct MobileLocalDirectTerminalRenderer: UIViewControllerRepresentable {
    @Bindable private var session: MobileLocalDirectTerminalSession
    private let theme: TerminalTheme
    private let tracker: MobileKeyboardFrameTracker
    /// Composes the existing emulator and keyboard host, without cloud shell state.
    public init(session: MobileLocalDirectTerminalSession, theme: TerminalTheme, keyboardFrameTracker: MobileKeyboardFrameTracker) {
        self.session = session; self.theme = theme; tracker = keyboardFrameTracker
    }
    public func makeCoordinator() -> MobileLocalDirectTerminalRendererCoordinator {
        MobileLocalDirectTerminalRendererCoordinator(session: session)
    }
    public func makeUIViewController(context: Context) -> UIViewController {
        do {
            let surface = GhosttySurfaceView(runtime: try GhosttyRuntime.shared(), delegate: context.coordinator,
                fontSize: 12, terminalTheme: theme, terminalConfigTheme: theme, toolbarPresentation: .terminalOnly)
            surface.localEmulation = .mirror
            surface.scrollPresentationAuthority = .legacyMirror
            surface.artifactFilesEnabled = false
            surface.autoFocusOnWindowAttach = false
            surface.hostSurfaceID = session.surfaceID
            context.coordinator.surface = surface
            return GhosttySurfaceHostViewController(hostView: GhosttySurfaceHostView(surfaceView: surface, keyboardFrameTracker: tracker))
        } catch {
            session.rendererUnavailable()
            return UIViewController()
        }
    }
    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        // A normal resize/replay must not dismiss the keyboard and change the
        // viewport again. The session still accepts bytes only when ready.
        let retainsFocus = session.state == .ready || session.state == .loading
        context.coordinator.surface?.isUserInteractionEnabled = retainsFocus
        if !retainsFocus { context.coordinator.surface?.resignCurrentInput() }
    }
    public static func dismantleUIViewController(_ controller: UIViewController, coordinator: MobileLocalDirectTerminalRendererCoordinator) {
        coordinator.session.unmount()
        coordinator.surface?.prepareForDismantle()
        coordinator.surface = nil
    }
}
#endif
