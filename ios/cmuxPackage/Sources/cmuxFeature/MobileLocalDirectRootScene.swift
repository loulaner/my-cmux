import CmuxMobileShell
import CmuxMobileShellUI
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation
import SwiftUI

/// Account-free connection form and existing-terminal renderer.
@MainActor
public struct MobileLocalDirectRootScene: View {
    @Bindable private var controller: MobileLocalDirectClientController
    @State private var confirmsForget = false
    @State private var workspacePresentation: WorkspacePresentation?
    private enum WorkspacePresentation: Identifiable {
        case changes(MobileLocalDirectChangesSession)
        case files(MobileLocalDirectFilesSession)
        var id: ObjectIdentifier {
            switch self {
            case .changes(let session): ObjectIdentifier(session)
            case .files(let session): ObjectIdentifier(session)
            }
        }
    }
    private let keyboardFrameTracker: MobileKeyboardFrameTracker
    /// Uses the application's foreground connection owner and app-lifetime keyboard tracker.
    public init(controller: MobileLocalDirectClientController, keyboardFrameTracker: MobileKeyboardFrameTracker) {
        self.controller = controller
        self.keyboardFrameTracker = keyboardFrameTracker
    }

    public var body: some View {
        Group {
            if controller.state == .connected {
                NavigationSplitView {
                    List(selection: selection) {
                        ForEach(controller.workspaces) { workspace in
                            Section {
                                ForEach(workspace.terminals, id: \.id) { terminal in
                                    NavigationLink(value: terminal.id) { Text(verbatim: terminal.title) }
                                }
                            } header: { Text(verbatim: workspace.title) }
                        }
                    }
                    .navigationTitle(String(localized: "direct.ipad.terminals", defaultValue: "Existing Terminals"))
                    .toolbar {
                        Button(String(localized: "direct.ipad.disconnect", defaultValue: "Disconnect")) {
                            Task { await controller.disconnect() }
                        }
                    }
                } detail: {
                    if let session = controller.terminalSession {
                        ZStack {
                            MobileLocalDirectTerminalRenderer(session: session, theme: controller.terminalTheme,
                                                              keyboardFrameTracker: keyboardFrameTracker)
                                .id("\(controller.connectionGeneration):\(session.surfaceID)")
                                .ignoresSafeArea(.container, edges: .bottom)
                                .ignoresSafeArea(.keyboard, edges: .bottom)
                            if session.state != .ready {
                                VStack(spacing: 16) {
                                    if session.state == .loading { ProgressView() }
                                    Text(terminalStatus(session.state))
                                    if session.state == .detached {
                                        Button(String(localized: "direct.ipad.reattach", defaultValue: "Reattach Terminal")) {
                                            session.reattach()
                                        }
                                    } else if session.state == .failed || session.state == .incompatible {
                                        Button(String(localized: "direct.ipad.retryTerminal", defaultValue: "Reconnect and Retry")) {
                                            Task { await controller.connectRemembered() }
                                        }
                                    }
                                }
                                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding()
                            }
                        }
                        .navigationTitle(selectedTitle ?? "")
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                if let changesSession = controller.changesSession {
                                    Button {
                                        workspacePresentation = .changes(changesSession)
                                    } label: {
                                        Label(String(localized: "direct.changes.title", defaultValue: "Git Changes"),
                                              systemImage: "doc.text.magnifyingglass")
                                    }
                                }
                                if let filesSession = controller.filesSession {
                                    Button {
                                        workspacePresentation = .files(filesSession)
                                    } label: {
                                        Label(String(localized: "direct.files.title", defaultValue: "Files"), systemImage: "folder")
                                    }
                                }
                            }
                        }
                    } else {
                        Text(String(localized: "direct.ipad.choose", defaultValue: "Choose an existing terminal"))
                    }
                }
                // The UIKit terminal host owns keyboard reservation; do not apply it a second time in SwiftUI.
                .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                NavigationStack {
                    Form {
                        Section {
                            TextField(String(localized: "direct.ipad.address", defaultValue: "Mac Tailscale IPv4 address"), text: $controller.address)
                                #if os(iOS)
                                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled().disabled(busy)
                            TextField(String(localized: "direct.ipad.port", defaultValue: "TCP port"), text: $controller.port)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .disabled(busy)
                            Text(String(localized: "direct.ipad.approvalHint", defaultValue: "Connect both devices to Tailscale, then open the pairing window on your Mac."))
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            if busy { ProgressView().accessibilityLabel(status) }
                            Text(status)
                            if controller.isRemembered {
                                Button(String(localized: "direct.ipad.connectSaved", defaultValue: "Connect to Saved Mac")) {
                                    Task { await controller.connectRemembered() }
                                }.disabled(busy)
                            }
                            Button(controller.isRemembered
                                ? String(localized: "direct.ipad.pairAgain", defaultValue: "Request New Approval")
                                : String(localized: "direct.ipad.pair", defaultValue: "Connect and Request Approval")) {
                                Task { await controller.pair() }
                            }.buttonStyle(.borderedProminent).disabled(busy || !validDraft)
                            if busy {
                                Button(String(localized: "direct.ipad.disconnect", defaultValue: "Disconnect")) {
                                    Task { await controller.disconnect() }
                                }
                            }
                        }
                        if controller.isRemembered || controller.state == .error(.recordUnavailable) {
                            Section {
                                Button(String(localized: "direct.ipad.forget", defaultValue: "Forget This Mac"), role: .destructive) {
                                    confirmsForget = true
                                }
                            }
                        }
                    }
                    .navigationTitle(String(localized: "direct.ipad.title", defaultValue: "Mac Direct Connection"))
                }
            }
        }
        .sheet(item: $workspacePresentation) { presentation in
            switch presentation {
            case .changes(let session):
                MobileLocalDirectChangesView(session: session)
            case .files(let session):
                let terminal = controller.terminalSession
                let terminalTitle = terminal.flatMap { target in
                    controller.workspaces.first(where: { $0.id == target.workspaceID })?
                        .terminals.first(where: { $0.id == target.surfaceID })?.title
                }
                MobileLocalDirectFilesView(session: session, terminalTitle: terminalTitle,
                    canQueuePath: { [session, terminal] child in
                        guard let terminal else { return false }
                        return controller.canQueueUploadedPath(from: session, upload: child, into: terminal)
                    },
                    queuePath: { [session, terminal] child in
                        guard let terminal else { return false }
                        return controller.queueUploadedPath(from: session, upload: child, into: terminal)
                    })
            }
        }
        .onChange(of: controller.changesSession.map { ObjectIdentifier($0) }) { _, identity in
            if case .changes(let session) = workspacePresentation, ObjectIdentifier(session) != identity {
                workspacePresentation = nil
            }
        }
        .onChange(of: controller.filesSession.map { ObjectIdentifier($0) }) { _, identity in
            if case .files(let session) = workspacePresentation, ObjectIdentifier(session) != identity {
                workspacePresentation = nil
            }
        }
        .confirmationDialog(String(localized: "direct.ipad.forgetTitle", defaultValue: "Forget this Mac?"),
                            isPresented: $confirmsForget, titleVisibility: .visible) {
            Button(String(localized: "direct.ipad.forget", defaultValue: "Forget This Mac"), role: .destructive) {
                Task { await controller.forget() }
            }
            Button(String(localized: "direct.ipad.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "direct.ipad.forgetHint", defaultValue: "This removes the credential from this iPad only. To revoke access, remove this device on the Mac."))
        }
    }

    private func terminalStatus(_ state: MobileLocalDirectTerminalSession.State) -> String {
        switch state {
        case .ready: ""
        case .loading: String(localized: "direct.ipad.terminalLoading", defaultValue: "Restoring terminal display. Input is paused.")
        case .disconnected: String(localized: "direct.ipad.terminalOffline", defaultValue: "Terminal disconnected. Input is disabled.")
        case .detached: String(localized: "direct.ipad.terminalDetached", defaultValue: "This terminal is detached. Reattach to resume input.")
        case .incompatible: String(localized: "direct.ipad.terminalIncompatible", defaultValue: "The terminal display is incompatible with this Mac. Input is disabled.")
        case .failed: String(localized: "direct.ipad.terminalFailed", defaultValue: "The terminal stopped. Unconfirmed input will not be resent.")
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { controller.selectedSurfaceID }, set: { value in
            guard let value, let workspace = controller.workspaces.first(where: { $0.terminals.contains(where: { $0.id == value }) }) else { return }
            controller.select(workspaceID: workspace.id, surfaceID: value)
        })
    }
    private var selectedTitle: String? {
        controller.workspaces.first(where: { $0.id == controller.selectedWorkspaceID })?.terminals
            .first(where: { $0.id == controller.selectedSurfaceID })?.title
    }
    private var validDraft: Bool {
        guard let port = Int(controller.port) else { return false }
        return (try? CmxLocalTCPListenerConfiguration(address: controller.address, port: port)) != nil
    }
    private var busy: Bool {
        switch controller.state {
        case .connecting, .waitingApproval, .reconnecting: true
        default: false
        }
    }
    private var status: String {
        switch controller.state {
        case .disconnected: String(localized: "direct.ipad.disconnected", defaultValue: "Disconnected")
        case .connecting: String(localized: "direct.ipad.connecting", defaultValue: "Connecting…")
        case .waitingApproval: String(localized: "direct.ipad.waiting", defaultValue: "Approve this iPad on your Mac.")
        case .connected: String(localized: "direct.ipad.connected", defaultValue: "Connected")
        case .reconnecting: String(localized: "direct.ipad.reconnecting", defaultValue: "Reconnecting…")
        case .error(.needsApproval): String(localized: "direct.ipad.needsApproval", defaultValue: "Access was not approved. Request new approval on the Mac.")
        case .error(.hostChanged): String(localized: "direct.ipad.hostChanged", defaultValue: "The Mac identity has changed. Connection refused.")
        case .error(.recordUnavailable): String(localized: "direct.ipad.recordError", defaultValue: "The saved record cannot be used. Forget it or request new approval.")
        case .error(.saveFailed): String(localized: "direct.ipad.saveError", defaultValue: "The credential could not be saved. The connection was closed.")
        case .error(.invalidInput): String(localized: "direct.ipad.inputError", defaultValue: "Enter a valid Tailscale IPv4 address and TCP port.")
        case .error(.incompatibleHost): String(localized: "direct.ipad.protocolError", defaultValue: "The Mac returned an unsupported response.")
        case .error(.networkUnavailable): String(localized: "direct.ipad.networkError", defaultValue: "Cannot connect. Check Tailscale and the Mac listener.")
        }
    }
}
