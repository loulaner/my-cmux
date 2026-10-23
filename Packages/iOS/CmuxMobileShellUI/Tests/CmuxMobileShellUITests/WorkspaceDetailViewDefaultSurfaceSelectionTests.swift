#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileToast
import Foundation
import Observation
import SwiftUI
import Testing
@preconcurrency import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceDetailViewDefaultSurfaceSelectionTests {
    @Test func browserOnlyWorkspaceAutoSelectsItsFirstStreamPanelWhenPanelsArrive() async {
        let workspaceID = "workspace-1"
        let initialWorkspace = MobileWorkspacePreview(
            id: .init(rawValue: workspaceID),
            name: "Workspace",
            terminals: []
        )
        let updatedWorkspace = MobileWorkspacePreview(
            id: .init(rawValue: workspaceID),
            name: "Workspace",
            terminals: []
        )
        let browserStore = BrowserSurfaceStore()
        let browserStreamStore = BrowserStreamStore()
        let shell = MobileShellComposite(
            workspaces: [initialWorkspace],
            browserStreamEvents: browserStreamStore
        )
        let displaySettings = MobileDisplaySettings(
            defaults: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        )
        let toasts = ToastCenter()
        let model = WorkspaceDetailHarnessModel(workspace: initialWorkspace)

        let controller = UIHostingController(
            rootView: WorkspaceDetailHarness(
                model: model,
                store: shell,
                browserStore: browserStore,
                browserStreamStore: browserStreamStore,
                displaySettings: displaySettings,
                toasts: toasts
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        #expect(browserStreamStore.activeState(in: workspaceID) == nil)

        model.workspace = updatedWorkspace
        browserStreamStore.replaceBrowserPanels(in: workspaceID, with: [Self.browserDescriptor()])
        controller.view.layoutIfNeeded()
        await Self.waitForActivePanel(
            expectedID: Self.browserDescriptor().panelID,
            activeID: { browserStreamStore.activeState(in: workspaceID)?.id }
        )
        controller.view.layoutIfNeeded()

        #expect(browserStreamStore.activeState(in: workspaceID)?.id == Self.browserDescriptor().panelID)
        window.isHidden = true
    }

    private static func waitForActivePanel(
        expectedID: String,
        activeID: @escaping @MainActor () -> String?
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while activeID() != expectedID, clock.now < deadline {
            await Task.yield()
        }
    }

    private static func browserDescriptor() -> MobileBrowserPanelDescriptor {
        MobileBrowserPanelDescriptor(
            panelID: "browser-1",
            workspaceID: "workspace-1",
            url: nil,
            title: "Browser",
            pageWidth: 800,
            pageHeight: 600,
            canGoBack: false,
            canGoForward: false,
            isLoading: false
        )
    }
}

private struct WorkspaceDetailHarness: View {
    @Bindable var model: WorkspaceDetailHarnessModel
    let store: MobileShellComposite
    let browserStore: BrowserSurfaceStore
    let browserStreamStore: BrowserStreamStore
    let displaySettings: MobileDisplaySettings
    let toasts: ToastCenter

    var body: some View {
        WorkspaceDetailView(
            connectionStatus: .connected,
            workspace: model.workspace,
            store: store,
            createWorkspace: {},
            canCreateWorkspace: false,
            createTerminal: {},
            renameWorkspace: nil,
            customizeWorkspace: nil,
            setWorkspaceUnread: nil,
            closeWorkspace: nil,
            reportTerminalViewport: { _, _, _ in },
            sendTerminalInput: { _ in },
            safeAreaContext: .fullWidth,
            backButtonConfiguration: nil,
            signOut: nil
        )
        .environment(browserStore)
        .environment(browserStreamStore)
        .environment(displaySettings)
        .environment(toasts)
    }
}

@MainActor
@Observable
private final class WorkspaceDetailHarnessModel {
    var workspace: MobileWorkspacePreview

    init(workspace: MobileWorkspacePreview) {
        self.workspace = workspace
    }
}
#endif
