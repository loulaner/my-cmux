import CmuxMobileShell
import Foundation
import SwiftUI

/// Plain text from one immutable captured selection; the Files owner retires it.
@MainActor
struct MobileLocalDirectFilePreviewView: View {
    @Bindable var session: MobileLocalDirectFilePreviewSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: session.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MobileLocalDirectFileDownloadView(session: session)
                    .id(ObjectIdentifier(session))
                Divider()
                switch session.state {
                case .idle, .loading:
                    ProgressView(String(localized: "direct.preview.loading", defaultValue: "Loading preview…"))
                case .ready:
                    if let text = session.text, let totalBytes = session.totalBytes {
                        LabeledContent(String(localized: "direct.preview.displayedSize", defaultValue: "Displayed")) {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(session.displayedByteCount), countStyle: .file))
                        }
                        LabeledContent(String(localized: "direct.preview.totalSize", defaultValue: "File size")) {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                        }
                        if session.truncated {
                            Text(String(localized: "direct.preview.truncated", defaultValue: "Only the beginning of this file is shown."))
                                .foregroundStyle(.secondary)
                        }
                        if text.isEmpty {
                            Text(String(localized: "direct.preview.empty", defaultValue: "This file is empty."))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: text)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(failureMessage(.invalidResponse))
                    }
                case .failed(let failure):
                    Text(failureMessage(failure))
                    if canRetry {
                        Button(String(localized: "direct.changes.retry", defaultValue: "Try Again")) { session.refresh() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(Text(verbatim: session.path.split(separator: "/").last.map(String.init) ?? session.path))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "direct.changes.refresh", defaultValue: "Refresh")) { session.refresh() }
                    .disabled(session.state == .loading || !canRetry)
            }
        }
        .task(id: ObjectIdentifier(session)) {
            guard !Task.isCancelled, session.state == .idle else { return }
            session.refresh()
        }
    }

    private var canRetry: Bool {
        switch session.state {
        case .failed(.directoryChanged), .failed(.disconnected): false
        default: true
        }
    }

    private func failureMessage(_ failure: MobileLocalDirectFilePreviewSession.Failure) -> String {
        switch failure {
        case .invalidSelection:
            String(localized: "direct.preview.error.invalidSelection", defaultValue: "Choose an available file from the folder list.")
        case .unsupported:
            String(localized: "direct.preview.error.unsupported", defaultValue: "This Mac does not support file previews.")
        case .unsupportedWorkspace:
            String(localized: "direct.preview.error.unsupportedWorkspace", defaultValue: "File previews are available only for local workspaces.")
        case .permissionDenied:
            String(localized: "direct.preview.error.permissionDenied", defaultValue: "File access is disabled or not permitted.")
        case .fileUnavailable:
            String(localized: "direct.preview.error.fileUnavailable", defaultValue: "This file or workspace is no longer available.")
        case .directoryChanged:
            String(localized: "direct.preview.error.directoryChanged", defaultValue: "Workspace folder changed. Go back and refresh the folder.")
        case .fileChanged:
            String(localized: "direct.preview.error.fileChanged", defaultValue: "The file changed while being read. Try again.")
        case .unsupportedContent:
            String(localized: "direct.preview.error.unsupportedContent", defaultValue: "This file cannot be shown as a text preview.")
        case .invalidResponse:
            String(localized: "direct.preview.error.invalidResponse", defaultValue: "The Mac returned an invalid file preview.")
        case .unavailable:
            String(localized: "direct.preview.error.unavailable", defaultValue: "Could not load this preview. Try again.")
        case .disconnected:
            String(localized: "direct.preview.error.disconnected", defaultValue: "The connection has ended. Reconnect to preview files.")
        }
    }
}
