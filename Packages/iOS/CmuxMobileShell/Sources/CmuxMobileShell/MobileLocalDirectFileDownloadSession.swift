import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import Observation

/// Explicit complete-file integrity verification on a shared connection, without owning that connection.
///
/// Retains at most 2 MiB of verified raw bytes in memory. It does not save or interpret content.
/// Integrity is not authorization and does not prove that a host described its file truthfully.
///
/// ```swift
/// let download = try MobileLocalDirectFileDownloadSession(
///     rpc: rpc, workspaceID: workspaceID, connectionGeneration: generation,
///     path: path, rootID: rootID, capabilities: capabilities
/// )
/// download.refresh()
/// ```
@MainActor @Observable
public final class MobileLocalDirectFileDownloadSession {
    /// Safe failures without raw server messages or content.
    public enum Failure: Error, Equatable, Sendable {
        /// The immutable selection is invalid.
        case invalidSelection
        /// The host does not support this operation.
        case unsupported
        /// The workspace is not local and eligible.
        case unsupportedWorkspace
        /// Policy or filesystem permissions deny access.
        case permissionDenied
        /// The selected workspace or file is unavailable.
        case fileUnavailable
        /// The workspace root changed.
        case directoryChanged
        /// Observable file metadata changed during reading.
        case fileChanged
        /// The selected object is not a regular file.
        case notAFile
        /// The complete file exceeds the fixed 2 MiB limit.
        case tooLarge
        /// The wire response is malformed or belongs to another selection.
        case invalidResponse
        /// An otherwise unclassified safe failure.
        case unavailable
        /// The connection or this session was retired.
        case disconnected
    }
    /// Readiness of this immutable selection.
    public enum LoadState: Equatable, Sendable {
        /// No current read, including an explicitly cancelled read.
        case idle
        /// A current explicit read is pending.
        case loading
        /// Verified complete bytes and metadata are available.
        case ready
        /// No content remains after a safe failure.
        case failed(Failure)
    }
    /// Original workspace spelling sent on the wire.
    public let workspaceID: String
    /// Immutable parent connection epoch.
    public let connectionGeneration: UInt64
    /// Original root-relative file path.
    public let path: String
    /// Required consistency marker, not permission to read arbitrary paths.
    public let rootID: String
    /// Last validated path component, never a URL or a host-supplied output location.
    public var filename: String { String(path.split(separator: "/").last!) }
    /// Verified complete bytes; a valid empty file is nonnil empty Data.
    public private(set) var data: Data?
    /// Verified lowercase SHA-256, cleared with the data.
    public private(set) var sha256: String?
    /// Exact verified byte count, zero before readiness and after failures.
    public private(set) var byteCount = 0
    /// Current read readiness.
    public private(set) var state: LoadState = .idle
    @ObservationIgnored private let rpc: any MobileSyncing
    @ObservationIgnored private let workspaceUUID: UUID
    @ObservationIgnored private let capable: Bool
    @ObservationIgnored private let decode: @Sendable (Data) async throws -> MobileWorkspaceFileDownloadResponse
    @ObservationIgnored private var active = true
    @ObservationIgnored private var token: UInt64 = 0
    // Internal read-only completion handle for cancellation-ignoring test responses.
    @ObservationIgnored private(set) var requestTask: Task<Void, Never>?

    /// Captures a validated selection without connecting or issuing any request.
    /// - Parameters:
    ///   - rpc: Controller-owned shared RPC.
    ///   - workspaceID: Valid UUID spelling retained verbatim.
    ///   - connectionGeneration: Parent connection epoch.
    ///   - path: Nonempty, unmodified safe relative path.
    ///   - rootID: Required 64-byte lowercase hexadecimal root marker.
    ///   - capabilities: Capabilities advertised on this connection.
    /// - Throws: ``Failure/invalidSelection`` for an invalid identity, path or marker.
    public convenience init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64,
                            path: String, rootID: String, capabilities: Set<String>) throws {
        let decoder = MobileWorkspaceFileDownloadDecoder()
        try self.init(rpc: rpc, workspaceID: workspaceID, connectionGeneration: connectionGeneration,
                      path: path, rootID: rootID, capabilities: capabilities, decode: { try await decoder.decode($0) })
    }

    /// Instance-only seam for deterministic suspended-decoder tests; public construction uses the real actor.
    init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64,
         path: String, rootID: String, capabilities: Set<String>,
         decode: @escaping @Sendable (Data) async throws -> MobileWorkspaceFileDownloadResponse) throws {
        guard let uuid = UUID(uuidString: workspaceID), !path.isEmpty, path.utf8.count <= 4_096,
              !path.contains("\0"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }), rootID.utf8.count == 64,
              rootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidSelection }
        self.decode = decode
        self.rpc = rpc; self.workspaceID = workspaceID; workspaceUUID = uuid
        self.connectionGeneration = connectionGeneration; self.path = path; self.rootID = rootID
        capable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesDownload)
    }

    deinit { requestTask?.cancel() }

    /// Replaces any pending read with one explicit request; never retries automatically.
    public func refresh() {
        guard active else { return }
        requestTask?.cancel(); requestTask = nil; token &+= 1; clearContent()
        guard capable else { state = .failed(.unsupported); return }
        state = .loading
        let token = token, rpc = rpc
        do {
            let request = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString,
                "method": "mobile.workspace.files.download", "params": ["workspace_id": workspaceID, "path": path, "root_id": rootID]])
            requestTask = Task { [weak self] in
                guard self?.active == true, self?.token == token else { return }
                do {
                    let data = try await rpc.sendRequest(request, timeoutNanoseconds: nil)
                    guard let self, self.active, self.token == token else { return }
                    let download = try await self.decode(data)
                    guard self.active, self.token == token else { return }
                    guard UUID(uuidString: download.workspaceID) == self.workspaceUUID,
                          download.path.utf8.elementsEqual(self.path.utf8), download.rootID == self.rootID else {
                        throw Failure.invalidResponse
                    }
                    self.data = download.data; self.sha256 = download.sha256
                    self.byteCount = download.byteCount; self.state = .ready
                } catch {
                    guard let self, self.active, self.token == token else { return }
                    self.clearContent()
                    if error is CancellationError { self.state = .idle }
                    else if case .rpcError("cancelled", _) = error as? MobileShellConnectionError { self.state = .idle }
                    else { self.state = .failed(Self.failure(error)) }
                }
            }
        } catch { clearContent(); state = .failed(.unavailable) }
    }

    /// Permanently clears this selection and cancels only its own request.
    public func invalidate() {
        guard active else { return }
        active = false; token &+= 1; requestTask?.cancel(); requestTask = nil
        clearContent(); state = .failed(.disconnected)
    }

    private func clearContent() { data = nil; sha256 = nil; byteCount = 0 }

    private static func failure(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is DecodingError { return .invalidResponse }
        guard let error = error as? MobileShellConnectionError else { return .unavailable }
        switch error {
        case .connectionClosed: return .disconnected
        case .invalidResponse: return .invalidResponse
        case let .rpcError(code, _):
            switch code {
            case "invalid_params": return .invalidSelection
            case "method_not_found", "capability_disabled": return .unsupported
            case "unsupported_workspace": return .unsupportedWorkspace
            case "file_transfer_disabled", "forbidden", "permission_denied": return .permissionDenied
            case "root_changed", "workspace_changed": return .directoryChanged
            case "file_changed": return .fileChanged
            case "not_a_file": return .notAFile
            case "file_too_large": return .tooLarge
            case "file_not_found", "directory_not_found", "workspace_not_found", "workspace_unavailable": return .fileUnavailable
            case "admission_expired", "connection_closed", "disconnected": return .disconnected
            default: return .unavailable
            }
        default: return .unavailable
        }
    }
}
