import CmuxMobileRPC
import CmuxMobileShell
import Foundation
import SwiftUI

/// Single-page metadata browser; the captured session alone owns directory navigation.
@MainActor
struct MobileLocalDirectFilesView: View {
    @Bindable var session: MobileLocalDirectFilesSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "direct.files.metadataOnly", defaultValue: "Only folder browsing is available. File previews and transfers are not supported yet."))
                        .foregroundStyle(.secondary)
                    if session.parentPath != nil {
                        Button { session.goToParent() } label: {
                            Label(String(localized: "direct.files.up", defaultValue: "Parent Folder"), systemImage: "arrow.up")
                        }
                    }
                } header: {
                    if session.currentPath.isEmpty {
                        Text(String(localized: "direct.files.root", defaultValue: "Workspace Folder"))
                    } else {
                        Text(verbatim: session.currentPath)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textCase(nil)

                ForEach(session.entries, id: \.path) { entry in
                    if entry.kind == .directory {
                        Button { session.openDirectory(path: entry.path) } label: {
                            HStack {
                                entryLabel(entry)
                                Spacer()
                                Image(systemName: "chevron.forward").accessibilityHidden(true)
                            }
                        }
                        .disabled(session.state != .ready || entry.path.utf8.count > 4_096)
                        .accessibilityHint(String(localized: "direct.files.openHint", defaultValue: "Open Folder"))
                    } else {
                        entryLabel(entry)
                    }
                }

                switch session.state {
                case .idle, .loading:
                    ProgressView(String(localized: "direct.files.loading", defaultValue: "Loading folder…"))
                case .ready:
                    if session.entries.isEmpty {
                        Text(String(localized: "direct.files.empty", defaultValue: "This folder is empty."))
                    }
                    if session.nextOffset != nil {
                        Button(String(localized: "direct.files.loadMore", defaultValue: "Load More")) { session.loadNextPage() }
                    }
                case .failed(let failure):
                    Text(failureMessage(failure))
                    Button(String(localized: "direct.changes.retry", defaultValue: "Try Again")) { session.refresh() }
                }
            }
            .navigationTitle(String(localized: "direct.files.title", defaultValue: "Files"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "direct.changes.close", defaultValue: "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "direct.changes.refresh", defaultValue: "Refresh")) { session.refresh() }
                        .disabled(session.state == .loading)
                }
            }
        }
        .task(id: ObjectIdentifier(session)) {
            guard !Task.isCancelled, session.state != .loading else { return }
            session.refresh()
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func entryLabel(_ entry: MobileWorkspaceFileListResponse.Entry) -> some View {
        HStack {
            Image(systemName: icon(entry.kind)).accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(verbatim: entry.name).lineLimit(2).truncationMode(.middle)
                if entry.kind != .directory {
                    Text(kindLabel(entry.kind)).font(.caption).foregroundStyle(.secondary)
                }
                if entry.kind == .file, let size = entry.size {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(_ kind: MobileWorkspaceFileListResponse.Entry.Kind) -> String {
        switch kind {
        case .directory: "folder"
        case .file: "doc"
        case .symbolicLink: "link"
        case .other: "questionmark.folder"
        }
    }

    private func kindLabel(_ kind: MobileWorkspaceFileListResponse.Entry.Kind) -> String {
        switch kind {
        case .directory: String(localized: "direct.files.openHint", defaultValue: "Open Folder")
        case .file: String(localized: "direct.files.kind.file", defaultValue: "File")
        case .symbolicLink: String(localized: "direct.files.kind.link", defaultValue: "Symbolic Link")
        case .other: String(localized: "direct.files.kind.other", defaultValue: "Other Item")
        }
    }

    private func failureMessage(_ failure: MobileLocalDirectFilesSession.Failure) -> String {
        switch failure {
        case .invalidSelection:
            String(localized: "direct.files.error.invalidSelection", defaultValue: "Choose an available folder from the current list.")
        case .unsupported:
            String(localized: "direct.files.error.unsupported", defaultValue: "This Mac does not support folder browsing.")
        case .unsupportedWorkspace:
            String(localized: "direct.files.error.unsupportedWorkspace", defaultValue: "Folder browsing is available only for local workspaces.")
        case .permissionDenied:
            String(localized: "direct.files.error.permissionDenied", defaultValue: "Folder access is disabled or not permitted.")
        case .directoryUnavailable:
            String(localized: "direct.files.error.directoryUnavailable", defaultValue: "This folder or workspace is no longer available.")
        case .directoryChanged:
            String(localized: "direct.files.error.directoryChanged", defaultValue: "The folder changed. Refresh to load it again.")
        case .limitExceeded:
            String(localized: "direct.files.error.limitExceeded", defaultValue: "This folder has too many entries to browse.")
        case .invalidResponse:
            String(localized: "direct.files.error.invalidResponse", defaultValue: "The Mac returned an invalid folder response.")
        case .unavailable:
            String(localized: "direct.files.error.unavailable", defaultValue: "Could not load this folder. Try again.")
        case .disconnected:
            String(localized: "direct.files.error.disconnected", defaultValue: "The connection has ended.")
        }
    }
}
