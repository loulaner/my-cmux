import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

extension WorkspaceDetailView {
    @ViewBuilder
    var detailSurfaceContent: some View {
        #if os(iOS)
        let surface = activeSurface
        // Captured at body time (the same evaluation as `shouldAutoFocus` in
        // `detailContent()`), so a chrome-driven terminal switch — which
        // suppresses the target's autofocus until the remount's `onAppear`
        // consumes the suppression — cannot race that consumption and pop
        // the keyboard anyway.
        let refocusTerminalID = WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: selectedTerminal?.id.rawValue,
            shouldAutoFocusTerminal: { store.shouldAutoFocusTerminalSurface($0) },
            isComposerPresented: store.isComposerPresented
        )
        ZStack {
            detailContent()
                .opacity(surface == .terminal ? 1 : 0)
                .allowsHitTesting(surface == .terminal)
                .accessibilityHidden(surface != .terminal)
            if case let .macSurface(macSurface) = surface {
                macSurfaceContent(macSurface)
                    .background(store.activeTerminalTheme.terminalBackgroundColor)
                    // System colors, materials, and list backgrounds must
                    // resolve against the terminal theme the surface sits on,
                    // not the device appearance, or rows flash white over a
                    // dark theme (and vice versa).
                    .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
                    // Same recovery chrome as the terminal: the last synced
                    // surface stays visible, and connection state lives in
                    // the shared title bar (spinner while reconnecting, red
                    // dot + Reconnect menu item while disconnected).
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if workspaceChangesHint != nil {
                WorkspaceChangesHintBanner(
                    openChanges: openWorkspaceChanges,
                    dismiss: dismissWorkspaceChangesHint
                )
            }
        }
        .onChange(of: surface) { _, newSurface in
            if newSurface == .terminal {
                // The surface stayed mounted under the chrome, so no attach
                // autofocus fires on return; refocus explicitly. Never while
                // input is blocked: a disconnected terminal's keystrokes
                // drain silently, and the blocked observer won't re-fire to
                // resign a keyboard opened here.
                if let refocusTerminalID, !terminalInputIsBlocked {
                    GhosttySurfaceView.focusInput(surfaceID: refocusTerminalID)
                }
            } else {
                dismissTerminalKeyboardForChrome()
            }
        }
        #else
        detailContent()
        #endif
    }

    #if os(iOS)
    /// Kind → renderer dispatch for the selected non-terminal Mac surface.
    ///
    /// `MacSurfaceRenderer.resolve` owns the gating policy (capability +
    /// payload presence); unhandled kinds stay on the fallback card.
    @ViewBuilder
    func macSurfaceContent(_ macSurface: MobileSurfacePreview) -> some View {
        let renderer = MacSurfaceRenderer.resolve(
            surface: macSurface,
            supportsTodo: store.supportsTodo(in: workspace.id),
            supportsPanelArtifacts: store.supportsPanelArtifacts(in: workspace.id)
        )
        let openOnMac: () async -> Bool = { [store, workspaceID = workspace.id, surfaceID = macSurface.id] in
            await store.focusSurfaceOnMac(workspaceID: workspaceID, surfaceID: surfaceID)
        }
        let canOpenOnMac = store.supportsSurfaceFocus(in: workspace.id)
        switch renderer {
        case .todo(let todo):
            // The capability set empties while the connection recovers, so it
            // doubles as the "Mac can take mutations right now" signal; the
            // snapshot itself stays rendered either way.
            TodoSurfaceView(
                surface: macSurface,
                todo: todo,
                allowsMutations: store.supportsTodo(in: workspace.id)
            ) { mutation in
                try await store.performTodoMutation(mutation, workspaceID: workspace.id)
            }
            .id(macSurface.id.rawValue)
        case .filePreview(let path):
            PanelFileSurfaceView(
                surface: macSurface,
                path: path,
                loader: panelArtifactLoader(
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    surfaceID: macSurface.id.rawValue
                ),
                connectionStatus: effectiveConnectionStatus
            )
            .id(macSurface.id.rawValue)
        case .markdown(let path):
            MarkdownSurfaceView(
                surface: macSurface,
                path: path,
                loader: panelArtifactLoader(
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    surfaceID: macSurface.id.rawValue
                ),
                connectionStatus: effectiveConnectionStatus
            )
            .id(macSurface.id.rawValue)
        case .fallbackCard:
            SurfaceFallbackCardView(
                surface: macSurface,
                workspaceName: workspace.name,
                canOpenOnMac: canOpenOnMac,
                openOnMac: openOnMac
            )
        }
    }

    #endif
}
