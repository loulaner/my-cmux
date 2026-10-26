import CmuxMobileShell
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Two explicit actions: download verified bytes, then hand a snapshot to the system exporter.
@MainActor
struct MobileLocalDirectFileDownloadView: View {
    @Bindable var session: MobileLocalDirectFilePreviewSession
    @State private var exportState = MobileLocalDirectFileExportState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "direct.download.title", defaultValue: "Download File"))
                .font(.headline)
            Text(String(localized: "direct.download.availability", defaultValue: "Complete files up to 2 MiB. The Mac must support downloads."))
                .font(.caption).foregroundStyle(.secondary)
            if let child = session.downloadSession {
                switch child.state {
                case .idle: downloadButton
                case .loading:
                    ProgressView(String(localized: "direct.download.loading", defaultValue: "Downloading…"))
                    Button(String(localized: "direct.download.cancel", defaultValue: "Cancel")) { session.closeDownload() }
                case .ready:
                    LabeledContent(String(localized: "direct.download.verifiedSize", defaultValue: "Verified bytes")) {
                        Text(verbatim: String(child.byteCount))
                    }
                    Button(String(localized: "direct.download.save", defaultValue: "Save to Files…")) { save() }
                        .disabled(!session.canDownload || exportBusy)
                case .failed(let failure):
                    Text(failureMessage(failure))
                    if session.canDownload && !exportBusy { downloadButton }
                }
            } else { downloadButton }
            if let status = exportState.status {
                switch status {
                case .saved:
                    Text(String(localized: "direct.download.saved", defaultValue: "File saved."))
                case .failed:
                    Text(String(localized: "direct.download.saveFailed", defaultValue: "Could not save the file. Download it again and try saving."))
                }
            }
        }
        .background {
            if let snapshot = exportState.snapshot {
                Color.clear.fileExporter(
                    isPresented: $exportState.isPresented, document: snapshot.document,
                    contentTypes: [.data], defaultFilename: snapshot.filename,
                    onCompletion: { result in
                        let outcome: MobileLocalDirectFileExportState.Outcome
                        switch result {
                        case .success: outcome = .saved
                        case .failure: outcome = .failed
                        }
                        Task { @MainActor in complete(snapshot, outcome: outcome) }
                    },
                    onCancellation: { Task { @MainActor in complete(snapshot, outcome: .cancelled) } }
                )
            }
        }
        .onChange(of: session.downloadSession.map { ObjectIdentifier($0) }) { _, _ in
            exportState.invalidateIfSourceChanged(currentSource: session.downloadSession)
        }
        .onChange(of: session.state) { _, _ in exportState.reset() }
        .onDisappear { exportState.reset(); session.closeDownload() }
    }

    private var exportBusy: Bool { exportState.snapshot != nil || exportState.isPresented }

    private var downloadButton: some View {
        Button(String(localized: "direct.download.start", defaultValue: "Download")) {
            exportState.reset()
            session.startDownload()
        }
        .disabled(!session.canDownload || exportBusy)
    }

    private func save() {
        guard !exportBusy, session.canDownload, let child = session.downloadSession, child.state == .ready,
              let data = child.data, data.count == child.byteCount, child.sha256 != nil else { return }
        if !exportState.begin(source: child, data: data, filename: child.filename) { session.closeDownload() }
    }

    private func complete(_ snapshot: MobileLocalDirectFileExportState.Snapshot, outcome: MobileLocalDirectFileExportState.Outcome) {
        if exportState.finish(attemptID: snapshot.attemptID, currentSource: session.downloadSession, outcome: outcome),
           session.downloadSession === snapshot.source { session.closeDownload() }
    }

    private func failureMessage(_ failure: MobileLocalDirectFileDownloadSession.Failure) -> String {
        switch failure {
        case .invalidSelection:
            String(localized: "direct.download.error.invalidSelection", defaultValue: "Choose an available file from the folder list.")
        case .unsupported:
            String(localized: "direct.download.error.unsupported", defaultValue: "This Mac does not support file downloads.")
        case .unsupportedWorkspace:
            String(localized: "direct.download.error.unsupportedWorkspace", defaultValue: "File downloads are available only for local workspaces.")
        case .permissionDenied:
            String(localized: "direct.download.error.permissionDenied", defaultValue: "File access is disabled or not permitted.")
        case .fileUnavailable:
            String(localized: "direct.download.error.fileUnavailable", defaultValue: "This file or workspace is no longer available.")
        case .directoryChanged:
            String(localized: "direct.download.error.directoryChanged", defaultValue: "Workspace folder changed. Go back and refresh the folder.")
        case .fileChanged:
            String(localized: "direct.download.error.fileChanged", defaultValue: "The file changed while being read. Download it again.")
        case .notAFile:
            String(localized: "direct.download.error.notAFile", defaultValue: "This item is not a regular file.")
        case .tooLarge:
            String(localized: "direct.download.error.tooLarge", defaultValue: "The complete file exceeds 2 MiB and cannot be downloaded.")
        case .invalidResponse:
            String(localized: "direct.download.error.invalidResponse", defaultValue: "The Mac returned an invalid file download.")
        case .unavailable:
            String(localized: "direct.download.error.unavailable", defaultValue: "Could not download this file. Try again.")
        case .disconnected:
            String(localized: "direct.download.error.disconnected", defaultValue: "The connection has ended. Reconnect to download files.")
        }
    }
}
