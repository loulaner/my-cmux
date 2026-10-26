import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import Observation

/// Explicit metadata navigation on an existing connection, without owning that connection.
///
/// This session rejects observed root-marker changes during navigation and pagination; refresh or
/// recovery can rebind. Legacy responses cannot reliably reveal root changes. Neither mode provides an atomic directory
/// snapshot, stable cursor, strong inode ABA protection, authorization token or preview permission.
///
/// ```swift
/// let session = try MobileLocalDirectFilesSession(
///     rpc: rpc, workspaceID: workspaceID, connectionGeneration: generation, capabilities: capabilities
/// )
/// session.refresh()
/// ```
@MainActor @Observable
public final class MobileLocalDirectFilesSession {
    /// Safe failures without server messages or raw errors.
    public enum Failure: Error, Equatable, Sendable {
        /// The requested selection is not an eligible directory.
        case invalidSelection
        /// The connection does not advertise the required capability.
        case unsupported
        /// The workspace is not a supported local workspace.
        case unsupportedWorkspace
        /// Policy or filesystem permissions denied access.
        case permissionDenied
        /// The workspace or directory is unavailable.
        case directoryUnavailable
        /// The host scope or observed pagination changed.
        case directoryChanged
        /// The directory exceeded the host enumeration limit.
        case limitExceeded
        /// The response is malformed or belongs to another request context.
        case invalidResponse
        /// An otherwise unclassified safe failure.
        case unavailable
        /// The connection or session was retired.
        case disconnected
    }
    /// Readiness of the currently selected directory.
    public enum LoadState: Equatable, Sendable {
        /// No current read is in progress.
        case idle
        /// A first or next page is pending.
        case loading
        /// Validated entries are available for explicit actions.
        case ready
        /// The current read failed without exposing raw error details.
        case failed(Failure)
    }
    /// Original workspace spelling used for outbound requests.
    public let workspaceID: String
    /// Immutable parent connection generation.
    public let connectionGeneration: UInt64
    /// Current relative directory, preserved on failures for explicit recovery.
    public private(set) var currentPath = ""
    /// Validated accumulated entries; never a partial result after failure.
    public private(set) var entries: [MobileWorkspaceFileListResponse.Entry] = []
    /// Count observed by the first page, or nil when no valid pages remain.
    public private(set) var totalCount: Int?
    /// Next explicit page offset, or nil when complete or cleared.
    public private(set) var nextOffset: Int?
    /// Most recently accepted root marker; nil for an unbound session or legacy host.
    /// This observable consistency value does not grant access to file contents.
    public var rootID: String? {
        if case .observed(let marker) = rootBinding { return marker }
        return nil
    }
    /// The owned preview selection; creation alone performs no RPC.
    public private(set) var previewSession: MobileLocalDirectFilePreviewSession?
    /// Whether this ready, marked directory permits explicit file previews.
    public var canPreviewFiles: Bool { active && state == .ready && capable && previewCapable && rootID != nil }

    /// Whether a ready marked directory can open a file context for preview or download.
    public var canOpenFiles: Bool { active && state == .ready && capable && rootID != nil && (previewCapable || downloadCapable) }

    /// The owned one-shot upload; construction alone does not prepare or submit bytes.
    public private(set) var uploadSession: MobileLocalDirectFileUploadSession?
    /// Directory epoch captured together with this parent before any asynchronous picker.
    public var directoryRevision: UInt64 { token }
    /// Whether this ready marked directory can capture a new explicit upload selection.
    public var canUploadFiles: Bool {
        active && state == .ready && capable && uploadCapable && rootID != nil && uploadSession == nil
    }

    private enum RootBinding {
        case unbound
        case observed(String?)
    }
    private var rootBinding: RootBinding = .unbound
    /// Current read readiness.
    public private(set) var state: LoadState = .idle
    /// The only allowed upward navigation target; nil at the root.
    public var parentPath: String? {
        currentPath.isEmpty ? nil : currentPath.split(separator: "/").dropLast().joined(separator: "/")
    }
    @ObservationIgnored private let rpc: any MobileSyncing
    @ObservationIgnored private let workspaceUUID: UUID
    @ObservationIgnored private let capable: Bool
    @ObservationIgnored private let previewCapable: Bool
    @ObservationIgnored private let downloadCapable: Bool
    @ObservationIgnored private let uploadCapable: Bool
    @ObservationIgnored private var active = true
    @ObservationIgnored private var token: UInt64 = 0
    // Internal read-only completion handle, including cancellation-ignoring replies.
    @ObservationIgnored private(set) var requestTask: Task<Void, Never>?

    /// Stores the shared RPC and immutable selection without sending requests.
    /// - Parameters:
    ///   - rpc: Controller-owned shared RPC seam.
    ///   - workspaceID: Verified UUID string, kept verbatim for requests.
    ///   - connectionGeneration: Parent connection epoch.
    ///   - capabilities: Capabilities advertised on this connection.
    /// - Throws: ``Failure/invalidSelection`` for an invalid workspace identifier.
    public init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64, capabilities: Set<String>) throws {
        guard let uuid = UUID(uuidString: workspaceID) else { throw Failure.invalidSelection }
        self.rpc = rpc; self.workspaceID = workspaceID; workspaceUUID = uuid
        self.connectionGeneration = connectionGeneration
        capable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesList)
        previewCapable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesPreview)
        downloadCapable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesDownload)
        uploadCapable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesUpload)
    }

    deinit { requestTask?.cancel() }

    /// Discards previous pages and root binding, explicitly rebinding the current directory.
    public func refresh() {
        guard active else { return }
        clearPages()
        start(path: currentPath, offset: 0)
    }

    /// Opens only an exact directory path from the current validated page set.
    /// - Parameter path: Original UTF-8 entry path; links and arbitrary paths are not allowed.
    public func openDirectory(path: String) {
        guard active, state == .ready else { return }
        guard Self.validRequestPath(path), entries.contains(where: {
            $0.kind == .directory && $0.path.utf8.elementsEqual(path.utf8)
        }) else {
            clearPages(); state = .failed(.invalidSelection); return
        }
        start(path: path, offset: 0)
    }

    /// Cancels the current read and reads only the derived parent; a root call is a no-op.
    public func goToParent() {
        guard active, let parentPath else { return }
        start(path: parentPath, offset: 0)
    }

    /// Requests exactly one next page, without prefetch or a concurrent request.
    public func loadNextPage() {
        guard active, state == .ready, let nextOffset, case .observed = rootBinding else { return }
        start(path: currentPath, offset: nextOffset)
    }

    /// Replaces the preview only for an exact regular-file entry in the ready page set.
    /// - Parameter path: Original UTF-8 entry path, never an arbitrary or normalized selection.
    /// - Returns: Whether a zero-request child was created; rejection leaves directory state unchanged.
    @discardableResult
    public func openFile(path: String) -> Bool {
        guard active, state == .ready else { return false }
        closeUpload()
        closePreview()
        guard canOpenFiles, Self.validRequestPath(path), let rootID,
              entries.contains(where: { $0.kind == .file && $0.path.utf8.elementsEqual(path.utf8) }) else { return false }
        var capabilities: Set<String> = []
        if previewCapable { capabilities.insert(CmxLocalDirectCapabilities.workspaceFilesPreview) }
        if downloadCapable { capabilities.insert(CmxLocalDirectCapabilities.workspaceFilesDownload) }
        do {
            previewSession = try MobileLocalDirectFilePreviewSession(
                rpc: rpc, workspaceID: workspaceID, connectionGeneration: connectionGeneration,
                path: path, rootID: rootID, capabilities: capabilities
            )
            return true
        } catch { return false }
    }

    /// Captures a selection only for the same ready directory epoch, with zero RPC and hashing.
    /// - Parameters:
    ///   - fileName: Literal safe destination leaf.
    ///   - data: Complete bytes, at most 2 MiB.
    ///   - directoryRevision: Epoch captured before the asynchronous picker, not merely a matching path.
    /// - Returns: Whether a new child was stored; invalid input leaves preview and existing upload unchanged.
    @discardableResult
    public func prepareUpload(fileName: String, data: Data, directoryRevision: UInt64) -> Bool {
        guard directoryRevision == token, canUploadFiles, let rootID else { return false }
        do {
            let child = try MobileLocalDirectFileUploadSession(
                rpc: rpc, workspaceID: workspaceID, connectionGeneration: connectionGeneration,
                path: currentPath, rootID: rootID, fileName: fileName, data: data,
                capabilities: uploadCapable ? [CmxLocalDirectCapabilities.workspaceFilesUpload] : []
            )
            closePreview()
            uploadSession = child
            return true
        } catch { return false }
    }

    /// Retires only the owned upload, preserving folder, root, preview and shared connection.
    public func closeUpload() {
        uploadSession?.invalidate()
        uploadSession = nil
    }

    /// Invalidates only the owned preview, preserving directory state and the shared connection.
    public func closePreview() {
        previewSession?.invalidate()
        previewSession = nil
    }

    /// Permanently clears this session without disconnecting the shared RPC.
    public func invalidate() {
        guard active else { return }
        active = false; token &+= 1; requestTask?.cancel(); requestTask = nil
        clearPages(); currentPath = ""; state = .failed(.disconnected)
    }

    private func start(path: String, offset: Int) {
        closeUpload()
        closePreview()
        requestTask?.cancel(); requestTask = nil; token &+= 1
        let expectedBinding = rootBinding
        currentPath = path
        if offset == 0 { clearPages(preservingRoot: true) }
        guard capable else { clearPages(); state = .failed(.unsupported); return }
        state = .loading
        let token = token, rpc = rpc
        do {
            let request = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString,
                "method": "mobile.workspace.files.list", "params": ["workspace_id": workspaceID,
                    "path": path, "offset": offset, "limit": 100]])
            requestTask = Task { [weak self] in
                guard self?.active == true, self?.token == token else { return }
                do {
                    let data = try await rpc.sendRequest(request, timeoutNanoseconds: nil)
                    guard let self, self.active, self.token == token else { return }
                    try self.accept(MobileWorkspaceFileListResponse.decode(data), path: path, offset: offset, expectedBinding: expectedBinding)
                    self.state = .ready
                } catch {
                    guard let self, self.active, self.token == token else { return }
                    self.clearPages()
                    self.state = error is CancellationError ? .idle : .failed(Self.failure(error))
                }
            }
        } catch { clearPages(); state = .failed(.unavailable) }
    }

    private func accept(_ page: MobileWorkspaceFileListResponse, path: String, offset: Int, expectedBinding: RootBinding) throws {
        guard UUID(uuidString: page.workspaceID) == workspaceUUID, page.path.utf8.elementsEqual(path.utf8),
              page.limit == 100, page.offset == offset else { throw Failure.invalidResponse }
        if case .observed(let previous) = expectedBinding, page.rootID != previous { throw Failure.directoryChanged }
        if offset != 0 {
            guard offset == entries.count else { throw Failure.invalidResponse }
            guard page.totalCount == totalCount else { throw Failure.directoryChanged }
            if let last = entries.last, let first = page.entries.first,
               !last.name.utf8.lexicographicallyPrecedes(first.name.utf8) { throw Failure.invalidResponse }
            var identities = Set(entries.map(\.path))
            guard page.entries.allSatisfy({ identities.insert($0.path).inserted }),
                  entries.count + page.entries.count <= 10_000 else { throw Failure.invalidResponse }
        }
        rootBinding = .observed(page.rootID)
        entries.append(contentsOf: page.entries)
        totalCount = page.totalCount; nextOffset = page.nextOffset
    }

    private func clearPages(preservingRoot: Bool = false) {
        closeUpload()
        closePreview()
        entries = []; totalCount = nil; nextOffset = nil
        if !preservingRoot { rootBinding = .unbound }
    }

    private static func validRequestPath(_ path: String) -> Bool {
        path.utf8.count <= 4_096 && !path.contains("\0") && !path.isEmpty &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func failure(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is DecodingError { return .invalidResponse }
        guard let error = error as? MobileShellConnectionError else { return .unavailable }
        switch error {
        case .invalidResponse: return .invalidResponse
        case .connectionClosed: return .disconnected
        case let .rpcError(code, _):
            switch code {
            case "method_not_found", "capability_disabled": return .unsupported
            case "unsupported_workspace": return .unsupportedWorkspace
            case "file_transfer_disabled", "forbidden", "permission_denied": return .permissionDenied
            case "directory_not_found", "not_a_directory", "workspace_not_found", "workspace_unavailable": return .directoryUnavailable
            case "workspace_changed": return .directoryChanged
            case "limit_exceeded": return .limitExceeded
            case "connection_closed", "disconnected": return .disconnected
            default: return .unavailable
            }
        default: return .unavailable
        }
    }
}
