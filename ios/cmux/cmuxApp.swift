import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI
import cmuxFeature

/// Personal direct-only root. No cloud authentication, Iroh, push, or analytics owner is constructed.
@main
struct cmuxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardFrameTracker = MobileKeyboardFrameTracker()
    @State private var controller = makeController()

    private static func makeController() -> MobileLocalDirectClientController {
        #if DEBUG && CMUX_LOCAL_TERMINAL_ACCEPTANCE
        if LocalTerminalUIAcceptance.enabled { return LocalTerminalUIAcceptance.shared.controller }
        #endif
        return MobileLocalDirectClientController(store: MobileLocalDirectClientFileStore(
            baseURL: URL.applicationSupportDirectory.resolvingSymlinksInPath().appendingPathComponent("local-direct", isDirectory: true)))
    }

    var body: some Scene {
        WindowGroup {
            MobileLocalDirectRootScene(controller: controller, keyboardFrameTracker: keyboardFrameTracker)
                #if DEBUG && CMUX_LOCAL_TERMINAL_ACCEPTANCE
                .overlay(alignment: .topTrailing) {
                    if LocalTerminalUIAcceptance.enabled {
                        Text(verbatim: LocalTerminalUIAcceptance.shared.status)
                            .font(.caption).padding(4).background(.regularMaterial)
                            .accessibilityIdentifier("local-terminal-acceptance-status")
                            .allowsHitTesting(false)
                    }
                }
                #endif
                .task {
                    await controller.setForeground(scenePhase == .active)
                    #if DEBUG && CMUX_LOCAL_TERMINAL_ACCEPTANCE
                    if LocalTerminalUIAcceptance.enabled { await LocalTerminalUIAcceptance.shared.run() }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await controller.setForeground(true) } }
                    else if phase == .background { Task { await controller.setForeground(false) } }
                }
        }
    }
}
