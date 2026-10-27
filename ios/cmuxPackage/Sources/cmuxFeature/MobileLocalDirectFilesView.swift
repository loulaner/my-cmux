import CmuxMobileRPC
import CmuxMobileShell
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Single-page directory browser with a captured, separately owned text preview.
@MainActor
struct MobileLocalDirectFilesView: View {
    @Bindable var session: MobileLocalDirectFilesSession
    let terminalTitle: String?
    let canQueuePath: (MobileLocalDirectFileUploadSession) -> Bool
    let queuePath: (MobileLocalDirectFileUploadSession) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var previewPresentation: PreviewPresentation?
    @State private var importReader = MobileLocalDirectFileImportReader()
    @State private var importSession: MobileLocalDirectFileImportSession?

    private struct PreviewPresentation: Hashable {
        let session: MobileLocalDirectFilePreviewSession

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)
        }

        nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(session))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.state == .ready {
                        if session.canOpenFiles {
                            Text(String(localized: "direct.preview.availability", defaultValue: "Open a file to preview it or download it when supported by this Mac."))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "direct.files.metadataOnly", defaultValue: "File previews and downloads are unavailable for this folder."))
                                .foregroundStyle(.secondary)
                        }
                    }
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
                    } else if entry.kind == .file && session.canOpenFiles {
                        Button {
                            if session.openFile(path: entry.path), let child = session.previewSession {
                                previewPresentation = PreviewPresentation(session: child)
                            }
                        } label: {
                            HStack {
                                entryLabel(entry)
                                Spacer()
                                Image(systemName: "chevron.forward").accessibilityHidden(true)
                            }
                        }
                        .disabled(entry.path.utf8.count > 4_096)
                        .accessibilityHint(String(localized: "direct.preview.openHint", defaultValue: "Open File"))
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
            .navigationDestination(item: $previewPresentation) { presentation in
                MobileLocalDirectFilePreviewView(session: presentation.session)
            }
            .navigationTitle(String(localized: "direct.files.title", defaultValue: "Files"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "direct.changes.close", defaultValue: "Close")) { retireImport(); session.closeUpload(); session.closePreview(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "direct.changes.refresh", defaultValue: "Refresh")) { session.refresh() }
                        .disabled(session.state == .loading)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if previewPresentation == nil {
                MobileLocalDirectFileUploadView(session: session, importSession: importSession,
                                                chooseFile: chooseFile, choosePhoto: choosePhoto, doneAndRefresh: doneAndRefresh,
                                                terminalTitle: terminalTitle, canQueuePath: canQueuePath,
                                                queuePath: queuePathAndShowTerminal)
            }
        }
        .background {
            if let selection = importSession {
                @Bindable var selection = selection
                switch selection.source {
                case .file:
                    Color.clear.fileImporter(
                        isPresented: $selection.isPickerPresented,
                        allowedContentTypes: [.data], allowsMultipleSelection: false,
                        onCompletion: { [selection] result in
                            Task { @MainActor in
                                guard importSession === selection else { return }
                                switch result {
                                case .success(let urls):
                                    guard urls.count == 1, let url = urls.first else { selection.pickerFailed(); return }
                                    selection.select(url: url)
                                case .failure: selection.pickerFailed()
                                }
                            }
                        },
                        onCancellation: { [selection] in
                            Task { @MainActor in
                                guard importSession === selection else { return }
                                selection.cancel()
                            }
                        }
                    )
                case .photo:
                    MobileLocalDirectPhotoPickerView(selection: selection) { [selection] in
                        importSession === selection
                    }
                    .id(ObjectIdentifier(selection))
                }
            }
        }
        .onChange(of: session.previewSession.map { ObjectIdentifier($0) }) { _, identity in
            if identity != nil { retireImport() }
            if let presentation = previewPresentation, ObjectIdentifier(presentation.session) != identity {
                previewPresentation = nil
            }
        }
        .onChange(of: previewPresentation) { old, new in
            if let old, new == nil, session.previewSession === old.session {
                session.closePreview()
            }
        }
        .onChange(of: session.directoryRevision) { _, _ in retireImport() }
        .onDisappear { retireImport(); session.closeUpload(); session.closePreview() }
        .task(id: ObjectIdentifier(session)) {
            guard !Task.isCancelled, session.state != .loading else { return }
            session.refresh()
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private var importBusy: Bool {
        importSession?.isBusy == true
    }

    private func chooseFile() {
        guard session.canUploadFiles, !importBusy else { return }
        retireImport()
        importSession = MobileLocalDirectFileImportSession(files: session, reader: importReader)
    }

    private func choosePhoto() {
        guard session.canUploadFiles, !importBusy else { return }
        retireImport()
        importSession = MobileLocalDirectFileImportSession(files: session, reader: importReader, source: .photo)
    }

    private func retireImport() {
        importSession?.invalidate(); importSession = nil
    }

    private func doneAndRefresh() {
        retireImport(); session.closeUpload(); session.refresh()
    }

    private func queuePathAndShowTerminal(_ child: MobileLocalDirectFileUploadSession) -> Bool {
        guard queuePath(child) else { return false }
        retireImport(); session.closePreview(); dismiss()
        return true
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
