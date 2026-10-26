import CmuxMobileRPC
import CmuxMobileShell
import SwiftUI

/// A read-only sheet bound to the exact connection/workspace session captured at presentation.
@MainActor
struct MobileLocalDirectChangesView: View {
    @Bindable var session: MobileLocalDirectChangesSession
    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath: [String] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                switch session.filesState {
                case .idle, .loading:
                    ProgressView(String(localized: "direct.changes.loading", defaultValue: "Loading changes…"))
                case .failed(let failure):
                    DirectChangesFailureView(failure: failure, retry: refresh)
                case .ready:
                    if let response = session.filesResponse {
                        if response.truncated {
                            Text(String(localized: "direct.changes.listTruncated", defaultValue: "Only part of the changed files list is shown."))
                                .foregroundStyle(.secondary)
                        }
                        if response.files.isEmpty {
                            Text(String(localized: "direct.changes.empty", defaultValue: "No changed files"))
                        }
                        ForEach(response.files, id: \.path) { file in
                            NavigationLink(value: file.path) {
                                VStack(alignment: .leading) {
                                    Text(verbatim: file.path)
                                        .lineLimit(2).truncationMode(.middle)
                                    if let oldPath = file.oldPath {
                                        Text(verbatim: oldPath)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(2).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    } else {
                        DirectChangesFailureView(failure: .invalidResponse, retry: refresh)
                    }
                }
            }
            .navigationTitle(String(localized: "direct.changes.title", defaultValue: "Git Changes"))
            .toolbar {
                if navigationPath.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "direct.changes.close", defaultValue: "Close")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(String(localized: "direct.changes.refresh", defaultValue: "Refresh"), action: refresh)
                            .disabled(session.filesState == .loading)
                    }
                }
            }
            .navigationDestination(for: String.self) { path in
                DirectChangesDetailView(session: session, path: path)
            }
        }
        .task(id: ObjectIdentifier(session)) {
            guard !Task.isCancelled, session.filesState != .loading else { return }
            refresh()
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func refresh() {
        navigationPath.removeAll()
        session.refresh()
    }
}

@MainActor
private struct DirectChangesDetailView: View {
    @Bindable var session: MobileLocalDirectChangesSession
    let path: String

    var body: some View {
        Group {
            switch session.diffState {
            case .idle, .loading:
                ProgressView(String(localized: "direct.changes.loading", defaultValue: "Loading changes…"))
            case .failed(let failure):
                DirectChangesFailureView(failure: failure) { session.selectFile(path: path) }
                    .padding()
            case .ready:
                if session.selectedPath == path, let diff = session.diffResponse, diff.path == path {
                    content(diff)
                } else {
                    ProgressView(String(localized: "direct.changes.loading", defaultValue: "Loading changes…"))
                }
            }
        }
        .navigationTitle(Text(verbatim: path))
        .task(id: path) {
            guard !Task.isCancelled else { return }
            session.selectFile(path: path)
        }
    }

    private func content(_ diff: MobileWorkspaceFileDiffResponse) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                if let oldPath = diff.oldPath {
                    Text(verbatim: oldPath).font(.caption).foregroundStyle(.secondary)
                }
                if diff.truncated {
                    Text(String(localized: "direct.changes.diffTruncated", defaultValue: "Only part of this diff is shown."))
                        .foregroundStyle(.secondary)
                }
                if diff.isBinary {
                    Text(String(localized: "direct.changes.binary", defaultValue: "Binary file — no text diff available"))
                } else if diff.unifiedDiff.isEmpty {
                    Text(String(localized: "direct.changes.emptyPreview", defaultValue: "No text preview available"))
                } else {
                    Text(verbatim: diff.unifiedDiff)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
    }
}

@MainActor
private struct DirectChangesFailureView: View {
    let failure: MobileLocalDirectChangesSession.Failure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
            Button(String(localized: "direct.changes.retry", defaultValue: "Try Again"), action: retry)
        }
    }

    private var message: String {
        switch failure {
        case .invalidSelection:
            String(localized: "direct.changes.error.invalidSelection", defaultValue: "Choose a file from the current changes list.")
        case .unsupported:
            String(localized: "direct.changes.error.unsupported", defaultValue: "This Mac does not support read-only changes.")
        case .notRepository:
            String(localized: "direct.changes.error.notRepository", defaultValue: "No local Git repository is available for this workspace.")
        case .permissionDenied:
            String(localized: "direct.changes.error.permissionDenied", defaultValue: "File access is disabled or not permitted.")
        case .invalidResponse:
            String(localized: "direct.changes.error.invalidResponse", defaultValue: "The Mac returned an invalid changes response.")
        case .unavailable:
            String(localized: "direct.changes.error.unavailable", defaultValue: "Could not load changes. Try again.")
        case .disconnected:
            String(localized: "direct.changes.error.disconnected", defaultValue: "The connection has ended.")
        }
    }
}
