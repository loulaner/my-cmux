import CmuxMobileShell
import Foundation
import SwiftUI

/// Explicit selection, confirmation and completion controls; lifetime belongs to the Files root.
@MainActor
struct MobileLocalDirectFileUploadView: View {
    @Bindable var session: MobileLocalDirectFilesSession
    let importSession: MobileLocalDirectFileImportSession?
    let chooseFile: () -> Void
    let choosePhoto: () -> Void
    let doneAndRefresh: () -> Void
    let terminalTitle: String?
    let canQueuePath: (MobileLocalDirectFileUploadSession) -> Bool
    let queuePath: (MobileLocalDirectFileUploadSession) -> Bool
    @State private var failedInsertion: MobileLocalDirectFileUploadSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "direct.upload.title", defaultValue: "Upload File")).font(.headline)
            Text(String(localized: "direct.upload.availability", defaultValue: "Choose one file up to 2 MiB. Existing files are never replaced."))
                .font(.caption).foregroundStyle(.secondary)
            if let child = session.uploadSession {
                uploadControls(child)
            } else {
                if let importSession {
                    switch importSession.state {
                    case .reading:
                        ProgressView(String(localized: "direct.upload.reading", defaultValue: "Reading selected file…"))
                        Button(String(localized: "direct.upload.cancel", defaultValue: "Cancel")) { self.importSession?.cancel() }
                    case .failed(let failure): Text(importFailureMessage(failure))
                    case .choosing, .prepared, .cancelled: EmptyView()
                    }
                }
                Button(String(localized: "direct.upload.choose", defaultValue: "Choose File…"), action: chooseFile)
                    .disabled(!session.canUploadFiles || importBusy)
                Button(String(localized: "direct.upload.choosePhoto", defaultValue: "Choose Photo…"), action: choosePhoto)
                    .disabled(!session.canUploadFiles || importBusy)
                Text(String(localized: "direct.upload.photoHint", defaultValue: "Select one image up to 2 MiB. This app doesn't resize or convert it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var importBusy: Bool {
        importSession?.isBusy == true
    }

    @ViewBuilder
    private func uploadControls(_ child: MobileLocalDirectFileUploadSession) -> some View {
        Text(verbatim: child.fileName).lineLimit(2).truncationMode(.middle)
        LabeledContent(String(localized: "direct.upload.size", defaultValue: "Selected file size")) {
            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(child.sourceByteCount), countStyle: .file))
        }
        LabeledContent(String(localized: "direct.upload.destination", defaultValue: "Destination folder")) {
            if child.path.isEmpty {
                Text(String(localized: "direct.files.root", defaultValue: "Workspace Folder"))
            } else { Text(verbatim: child.path).lineLimit(2).truncationMode(.middle) }
        }
        switch child.state {
        case .idle:
            Button(String(localized: "direct.upload.start", defaultValue: "Upload")) { child.start() }
        case .preparing:
            ProgressView(String(localized: "direct.upload.preparing", defaultValue: "Preparing upload…"))
            cancelButton(child)
        case .uploading:
            ProgressView(String(localized: "direct.upload.uploading", defaultValue: "Uploading…"))
            cancelButton(child)
        case .succeeded:
            Text(String(localized: "direct.upload.succeeded", defaultValue: "Upload confirmed by the Mac."))
            if let receipt = child.uploadedFile {
                Text(verbatim: receipt.path).lineLimit(2).truncationMode(.middle)
            }
            if let terminalTitle {
                LabeledContent(String(localized: "direct.upload.terminalTarget", defaultValue: "Selected terminal")) {
                    Text(verbatim: terminalTitle)
                }
            }
            Text(String(localized: "direct.upload.insertHint", defaultValue: "Queues a quoted path without pressing Return. Check the active program and input first."))
                .font(.caption).foregroundStyle(.secondary)
            Button(String(localized: "direct.upload.insert", defaultValue: "Insert Path and Show Terminal")) {
                if !queuePath(child) { failedInsertion = child }
            }
            .disabled(!canQueuePath(child))
            if failedInsertion === child {
                Text(String(localized: "direct.upload.insertFailed", defaultValue: "The path was not queued. Check the selected terminal and its input, then try again."))
            }
        case .failed(let failure): Text(failureMessage(failure))
        case .cancelled:
            Text(String(localized: "direct.upload.cancelled", defaultValue: "Upload cancelled on this device."))
        }
        if child.requiresFolderRefresh {
            Text(String(localized: "direct.upload.uncertain", defaultValue: "Upload may have completed. Refresh the folder before trying again."))
                .font(.callout)
        }
        switch child.state {
        case .succeeded, .failed, .cancelled:
            Button(String(localized: "direct.upload.done", defaultValue: "Done and Refresh"), action: doneAndRefresh)
        default: EmptyView()
        }
    }

    private func cancelButton(_ child: MobileLocalDirectFileUploadSession) -> some View {
        Button(String(localized: "direct.upload.cancel", defaultValue: "Cancel")) { child.cancel() }
    }

    private func importFailureMessage(_ failure: MobileLocalDirectFileImportSession.Failure) -> String {
        switch failure {
        case .invalidName:
            String(localized: "direct.upload.error.invalidName", defaultValue: "This filename cannot be uploaded. Rename the source file and choose it again.")
        case .notAFile:
            String(localized: "direct.upload.error.notAFile", defaultValue: "This item is not a regular file.")
        case .tooLarge: failureMessage(.tooLarge)
        case .permissionDenied: failureMessage(.permissionDenied)
        case .fileChanged: failureMessage(.fileChanged)
        case .directoryChanged: failureMessage(.directoryChanged)
        case .disconnected: failureMessage(.disconnected)
        case .unavailable: failureMessage(.unavailable)
        }
    }

    private func failureMessage(_ failure: MobileLocalDirectFileUploadSession.Failure) -> String {
        switch failure {
        case .invalidSelection:
            String(localized: "direct.upload.error.invalidSelection", defaultValue: "Choose a valid file and destination folder.")
        case .unsupported:
            String(localized: "direct.upload.error.unsupported", defaultValue: "This Mac does not support file uploads.")
        case .unsupportedWorkspace:
            String(localized: "direct.upload.error.unsupportedWorkspace", defaultValue: "Uploads are available only for local workspaces.")
        case .permissionDenied:
            String(localized: "direct.upload.error.permissionDenied", defaultValue: "File access is disabled or not permitted.")
        case .directoryUnavailable:
            String(localized: "direct.upload.error.directoryUnavailable", defaultValue: "This folder or workspace is no longer available.")
        case .directoryChanged:
            String(localized: "direct.upload.error.directoryChanged", defaultValue: "The folder changed. Refresh to load it again.")
        case .fileChanged:
            String(localized: "direct.upload.error.fileChanged", defaultValue: "The file changed. Choose it again.")
        case .alreadyExists:
            String(localized: "direct.upload.error.alreadyExists", defaultValue: "A file with this name already exists and will not be replaced. Rename the source file before choosing it again.")
        case .tooLarge:
            String(localized: "direct.upload.error.tooLarge", defaultValue: "Files must be 2 MiB or smaller.")
        case .integrityMismatch:
            String(localized: "direct.upload.error.integrityMismatch", defaultValue: "The Mac could not verify the uploaded bytes.")
        case .invalidResponse:
            String(localized: "direct.upload.error.invalidResponse", defaultValue: "The Mac returned an invalid upload acknowledgement.")
        case .unavailable:
            String(localized: "direct.upload.error.unavailable", defaultValue: "Could not prepare or upload this file.")
        case .disconnected:
            String(localized: "direct.upload.error.disconnected", defaultValue: "The selection or connection is no longer active.")
        case .notDirectory:
            String(localized: "direct.upload.error.notDirectory", defaultValue: "The destination is not a folder.")
        }
    }
}
