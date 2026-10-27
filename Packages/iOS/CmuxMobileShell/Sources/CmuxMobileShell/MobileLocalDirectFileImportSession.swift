public import Foundation
import Observation

/// One system-file selection bound to the original Files directory revision.
///
/// Preparation transfers bytes to the Files-owned upload child without submitting it.
/// Retiring this selection never retires an upload child, including one already transferred.
///
/// ```swift
/// let selection = MobileLocalDirectFileImportSession(files: files, reader: reader)
/// selection.select(url: selectedURL)
/// ```
@MainActor @Observable
public final class MobileLocalDirectFileImportSession {
    /// Safe selection failures without raw provider details or source URLs.
    public enum Failure: Error, Equatable, Sendable {
        /// The source name cannot be used as an upload leaf.
        case invalidName
        /// The source is not a regular file.
        case notAFile
        /// The source exceeds the 2 MiB budget.
        case tooLarge
        /// Source access was denied.
        case permissionDenied
        /// The source changed during the read.
        case fileChanged
        /// The original directory lease no longer matches.
        case directoryChanged
        /// The selection or connection was retired.
        case disconnected
        /// Selection, provider access, or preparation is unavailable.
        case unavailable
    }

    /// Selection lifecycle, separate from the child's upload lifecycle.
    public enum LoadState: Equatable, Sendable {
        /// Waiting for one system-picker result.
        case choosing
        /// Reading on the injected reader actor.
        case reading
        /// Bytes transferred to an idle Files-owned upload child.
        case prepared
        /// Quietly cancelled before transfer.
        case cancelled
        /// A safe failure with no retained source selection.
        case failed(Failure)
    }

    /// The system picker supplying this one-shot selection.
    public enum Source: Sendable {
        /// System file importer, with explicit completion/cancellation callbacks.
        case file
        /// Single image picker; dismissal may precede its selected item callback.
        case photo
    }
    /// Immutable picker source; changing sources requires a new selection owner.
    public let source: Source
    /// Reading always occupies the selection; a dismissed image picker can be replaced explicitly.
    public var isBusy: Bool {
        state == .reading || (state == .choosing && (source == .file || isPickerPresented))
    }

    /// Directory epoch captured at construction, never replaced by a newer lease.
    public let directoryRevision: UInt64
    /// Literal original destination directory, empty for workspace root.
    public let path: String
    /// Current selection lifecycle.
    public private(set) var state: LoadState
    /// System-picker binding; dismissal alone does not retire a pending completion.
    public var isPickerPresented: Bool

    @ObservationIgnored private let files: MobileLocalDirectFilesSession
    @ObservationIgnored private let read: @Sendable (URL) async throws -> MobileLocalDirectFileImportReader.Selection
    @ObservationIgnored private var active: Bool
    @ObservationIgnored private var token: UInt64 = 0
    @ObservationIgnored private(set) var requestTask: Task<Void, Never>?

    /// Captures a directory lease without reading or sending RPC.
    /// - Parameters:
    ///   - files: Strongly held parent, which must allow uploading with no open preview.
    ///   - reader: Stable caller-owned reader, reused across selections.
    ///   - source: Picker policy, defaulting to the existing file importer behavior.
    public convenience init(files: MobileLocalDirectFilesSession, reader: MobileLocalDirectFileImportReader, source: Source = .file) {
        self.init(files: files, read: { try await reader.read($0) }, source: source)
    }

    /// Instance-only async seam; public construction uses the actual reader actor.
    init(files: MobileLocalDirectFilesSession,
         read: @escaping @Sendable (URL) async throws -> MobileLocalDirectFileImportReader.Selection, source: Source = .file) {
        self.files = files; self.read = read; self.source = source
        directoryRevision = files.directoryRevision; path = files.currentPath
        active = files.canUploadFiles && files.previewSession == nil
        state = active ? .choosing : .failed(.unavailable)
        isPickerPresented = active
    }

    deinit { requestTask?.cancel() }

    /// Consumes at most one selected URL and prepares, but never starts, its upload.
    /// - Parameter url: The single system-selected source URL.
    public func select(url: URL) {
        let read = read
        select(load: { try await read(url) })
    }

    /// Loads one bounded selection and transfers it to an idle upload without submitting it.
    /// Late results are accepted only while this original directory and selection still own the operation.
    public func select(load: @escaping @Sendable () async throws -> MobileLocalDirectFileImportReader.Selection) {
        guard active, state == .choosing else { return }
        isPickerPresented = false; state = .reading
        let token = token
        requestTask = Task { [weak self] in
            do {
                let selection = try await load()
                guard let self, self.active, self.token == token else { return }
                if self.files.state == .failed(.disconnected) { throw Failure.disconnected }
                guard self.directoryRevision == self.files.directoryRevision else { throw Failure.directoryChanged }
                guard self.files.canUploadFiles, self.files.previewSession == nil,
                      self.files.prepareUpload(fileName: selection.fileName, data: selection.data,
                                               directoryRevision: self.directoryRevision) else { throw Failure.unavailable }
                self.state = .prepared
            } catch {
                guard let self, self.active, self.token == token else { return }
                if error is CancellationError { self.cancel() }
                else { self.active = false; self.state = .failed(Self.failure(error)) }
            }
        }
    }

    /// Reports malformed picker results or picker failure without exposing its raw error.
    public func pickerFailed() {
        guard active, state == .choosing else { return }
        active = false; isPickerPresented = false; state = .failed(.unavailable)
    }

    /// Quietly retires choosing/reading only; a transferred child remains owned by Files.
    public func cancel() {
        guard active, state == .choosing || state == .reading else { return }
        active = false; token &+= 1; isPickerPresented = false
        requestTask?.cancel(); requestTask = nil; state = .cancelled
    }

    /// Permanently retires this selection without closing any parent-owned upload.
    public func invalidate() {
        active = false; token &+= 1; isPickerPresented = false
        requestTask?.cancel(); requestTask = nil; state = .failed(.disconnected)
    }

    private static func failure(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        guard let error = error as? MobileLocalDirectFileImportReader.Failure else { return .unavailable }
        switch error {
        case .invalidName: return .invalidName
        case .notAFile: return .notAFile
        case .tooLarge: return .tooLarge
        case .permissionDenied: return .permissionDenied
        case .fileChanged: return .fileChanged
        case .unavailable: return .unavailable
        }
    }
}
