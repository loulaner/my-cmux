import Foundation

// Explicit uploaded-path admission uses only the controller's public read-only ownership state.
extension MobileLocalDirectClientController {
    /// Visible ownership/readiness only; pending input capacity is checked at explicit admission.
    public func canQueueUploadedPath(from files: MobileLocalDirectFilesSession,
                                     upload: MobileLocalDirectFileUploadSession,
                                     into terminal: MobileLocalDirectTerminalSession) -> Bool {
        uploadedPathQuote(from: files, upload: upload, into: terminal) != nil
    }

    /// Queues one quoted argument without Return. Success is local admission, not host acknowledgement.
    /// Only successful admission consumes this owned receipt; a rejected click may be explicitly retried.
    public func queueUploadedPath(from files: MobileLocalDirectFilesSession,
                                  upload: MobileLocalDirectFileUploadSession,
                                  into terminal: MobileLocalDirectTerminalSession) -> Bool {
        guard let quote = uploadedPathQuote(from: files, upload: upload, into: terminal),
              terminal.enqueueLiteralText(quote) else { return false }
        files.closeUpload()
        return true
    }

    private func uploadedPathQuote(from files: MobileLocalDirectFilesSession,
                                   upload: MobileLocalDirectFileUploadSession,
                                   into terminal: MobileLocalDirectTerminalSession) -> String? {
        guard state == .connected, filesSession === files, terminalSession === terminal,
              files.state == .ready, files.uploadSession === upload, terminal.state == .ready,
              files.connectionGeneration == connectionGeneration,
              upload.connectionGeneration == connectionGeneration,
              terminal.connectionGeneration == connectionGeneration,
              let selectedWorkspaceID, let workspace = UUID(uuidString: selectedWorkspaceID),
              UUID(uuidString: files.workspaceID) == workspace,
              UUID(uuidString: upload.workspaceID) == workspace,
              UUID(uuidString: terminal.workspaceID) == workspace,
              let selectedSurfaceID, let surface = UUID(uuidString: selectedSurfaceID),
              UUID(uuidString: terminal.surfaceID) == surface,
              workspaces.contains(where: {
                  UUID(uuidString: $0.id) == workspace && $0.terminals.contains(where: { UUID(uuidString: $0.id) == surface })
              }),
              files.currentPath.utf8.elementsEqual(upload.path.utf8),
              let rootID = files.rootID, rootID.utf8.elementsEqual(upload.rootID.utf8),
              let quote = upload.shellQuotedPath else { return nil }
        return quote
    }
}
