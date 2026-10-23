import CmuxMobileShell
import SwiftUI

extension WorkspaceDetailView {
    /// The SSH computer behind this workspace, or `nil` for Mac workspaces.
    var sshHostID: UUID? {
        let computers = store.sshComputers
        return workspace.macDeviceID.flatMap(computers.hostID(forIdentifier:))
            ?? computers.hostID(forIdentifier: workspace.id.rawValue)
    }

}

#if os(iOS)

/// The SFTP browser opened from an SSH terminal's Files chip.
struct SSHFilesContext: Identifiable {
    let id = UUID()
    let hostID: UUID
    /// The terminal whose current directory the browser opens at.
    let surfaceID: String
}

extension WorkspaceDetailView {
    /// Whether `terminalID` is an SSH terminal, whose Files chip browses the
    /// server instead of listing files a Mac found on screen.
    func isSSHTerminal(_ terminalID: String) -> Bool {
        store.sshComputers.hostID(forIdentifier: terminalID) != nil
    }

    /// The terminal Browse Files in the title menu opens at: the shown SSH
    /// terminal, `nil` for Mac workspaces.
    var sshFilesTerminalID: String? {
        guard let terminalID = selectedTerminal?.id.rawValue,
              isSSHTerminal(terminalID) else { return nil }
        return terminalID
    }

    /// Browse Files in the title menu: the Files chip's action for the shown
    /// terminal (HIG Toolbars: a document menu next to the title holds
    /// commands for the whole document).
    func browseFilesFromMenu() {
        guard let terminalID = sshFilesTerminalID else { return }
        presentSSHFiles(terminalID: terminalID)
    }

    /// Opens the file browser for an SSH terminal (Files chip, title menu).
    func presentSSHFiles(terminalID: String) {
        guard let hostID = store.sshComputers.hostID(forIdentifier: terminalID) else { return }
        dismissTerminalKeyboardForChrome()
        sshFilesContext = SSHFilesContext(hostID: hostID, surfaceID: terminalID)
    }

    func sshFilesSheet(_ context: SSHFilesContext) -> some View {
        let computers = store.sshComputers
        let surfaceID = context.surfaceID
        return SSHFileBrowserSheet(
            hostID: context.hostID,
            computers: computers,
            startDirectory: { await computers.currentDirectory(surfaceID: surfaceID) },
            insertPath: sshInsertPathAction(surfaceID: surfaceID)
        )
    }

    /// Types into the SSH terminal the browser was opened from, through the
    /// store's ordinary raw-input funnel, so it lands exactly like a keystroke.
    private func sshInsertPathAction(surfaceID: String) -> (String) -> Void {
        { [store] text in
            store.sendTerminalRawInput(Data(text.utf8), surfaceID: surfaceID)
        }
    }
}
#endif
