import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import Observation

/// One explicit, non-retryable upload selection on a controller-owned connection.
///
/// Cancellation or a rejected response after submission may still leave a published file.
/// This type neither rolls it back nor sends terminal input. A new attempt requires a new selection.
///
/// ```swift
/// let upload = try MobileLocalDirectFileUploadSession(rpc: rpc, workspaceID: workspaceID,
///     connectionGeneration: generation, path: directory, rootID: marker,
///     fileName: name, data: bytes, capabilities: capabilities)
/// upload.start()
/// ```
@MainActor @Observable
public final class MobileLocalDirectFileUploadSession {
    /// Safe failures without raw server messages or host paths.
    public enum Failure: Error, Equatable, Sendable {
        /// Invalid workspace, directory, marker or filename.
        case invalidSelection
        /// Upload is not supported by this connection.
        case unsupported
        /// The workspace is not an eligible local workspace.
        case unsupportedWorkspace
        /// Policy or permissions deny the operation.
        case permissionDenied
        /// The directory or workspace is unavailable.
        case directoryUnavailable
        /// The observed root or workspace scope changed.
        case directoryChanged
        /// Observable file metadata changed before publication.
        case fileChanged
        /// A destination already exists and must not be overwritten.
        case alreadyExists
        /// The complete input exceeds 2 MiB.
        case tooLarge
        /// The host rejected the submitted byte integrity.
        case integrityMismatch
        /// The acknowledgement is malformed or does not match this submission.
        case invalidResponse
        /// An unclassified failure, including busy or timeout.
        case unavailable
        /// The connection, admission or selection was retired.
        case disconnected
        /// A destination component is not a directory.
        case notDirectory
    }
    /// One-shot preparation and submission state, not a transaction rollback indicator.
    public enum LoadState: Equatable, Sendable {
        /// Selected without preparation or RPC.
        case idle
        /// Hashing and encoding are pending on the codec actor.
        case preparing
        /// The shared RPC call has begun.
        case uploading
        /// A matching acknowledgement was accepted.
        case succeeded
        /// Cancelled locally or remotely; submission may already have committed.
        case cancelled
        /// A safe failure, without retained source bytes or receipt.
        case failed(Failure)
    }
    /// Original workspace UUID spelling.
    public let workspaceID: String
    /// Immutable parent connection epoch.
    public let connectionGeneration: UInt64
    /// Literal target directory, including empty for root.
    public let path: String
    /// Required root consistency marker, not authorization.
    public let rootID: String
    /// Literal validated destination leaf.
    public let fileName: String
    /// Complete source size, retained without retaining its bytes.
    public let sourceByteCount: Int
    /// Current one-shot state.
    public private(set) var state: LoadState = .idle
    /// Matching small acknowledgement; never source bytes or base64.
    public private(set) var uploadedFile: MobileWorkspaceFileUploadResponse?
    /// Whether sendRequest was entered; does not prove delivery or non-commit.
    public private(set) var submissionStarted = false
    /// Conservative advice after a submission without a currently retained success.
    public var requiresFolderRefresh: Bool { submissionStarted && state != .succeeded }
    /// A standalone POSIX single argument for a future explicit action, never an automatic send.
    /// This does not account for existing command-line quoting or arbitrary interactive programs.
    public var shellQuotedPath: String? {
        guard active, state == .succeeded, let absolute = uploadedFile?.absolutePath,
              !absolute.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { return nil }
        return "'" + absolute.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// Whether this receipt offers a standalone argument; the future controller must still check ownership.
    public var canInsertPath: Bool { shellQuotedPath != nil }

    @ObservationIgnored private let rpc: any MobileSyncing
    @ObservationIgnored private let workspaceUUID: UUID
    @ObservationIgnored private let relativePath: String
    @ObservationIgnored private let capable: Bool
    @ObservationIgnored private let requestID = UUID()
    @ObservationIgnored private let prepare: @Sendable (MobileWorkspaceFileUploadCodec.Input) async throws -> MobileWorkspaceFileUploadCodec.Prepared
    @ObservationIgnored private let decode: @Sendable (Data) async throws -> MobileWorkspaceFileUploadResponse
    @ObservationIgnored private var sourceData: Data?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var token: UInt64 = 0
    @ObservationIgnored private(set) var requestTask: Task<Void, Never>?
    // Internal read-only lifetime evidence, not public exposure of the source.
    var retainsSourceData: Bool { sourceData != nil }

    /// Validates and stores a selection without hashing, RPC, connection or filesystem work.
    /// - Parameters:
    ///   - rpc: Parent-owned shared RPC.
    ///   - workspaceID: Valid UUID spelling retained verbatim.
    ///   - connectionGeneration: Parent connection epoch.
    ///   - path: Literal safe relative directory; empty means root.
    ///   - rootID: Required lowercase 64-byte hexadecimal marker.
    ///   - fileName: Safe leaf at most 255 UTF-8 bytes.
    ///   - data: Complete source, at most 2 MiB; empty is valid.
    ///   - capabilities: Actual advertised connection capabilities.
    /// - Throws: ``Failure/tooLarge`` for oversized data, otherwise ``Failure/invalidSelection`` for invalid selection.
    public convenience init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64,
                            path: String, rootID: String, fileName: String, data: Data, capabilities: Set<String>) throws {
        let codec = MobileWorkspaceFileUploadCodec()
        try self.init(rpc: rpc, workspaceID: workspaceID, connectionGeneration: connectionGeneration,
                      path: path, rootID: rootID, fileName: fileName, data: data, capabilities: capabilities,
                      prepare: { try await codec.prepare($0) }, decode: { try await codec.decode($0) })
    }

    /// Instance-only suspended-codec seam; public construction always uses the real actor.
    init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64,
         path: String, rootID: String, fileName: String, data: Data, capabilities: Set<String>,
         prepare: @escaping @Sendable (MobileWorkspaceFileUploadCodec.Input) async throws -> MobileWorkspaceFileUploadCodec.Prepared,
         decode: @escaping @Sendable (Data) async throws -> MobileWorkspaceFileUploadResponse) throws {
        guard data.count <= 2_097_152 else { throw Failure.tooLarge }
        let relativePath = path.isEmpty ? fileName : path + "/" + fileName
        guard let uuid = UUID(uuidString: workspaceID), path.utf8.count <= 4_096, !path.contains("\0"),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !fileName.isEmpty, fileName != ".", fileName != "..", fileName.utf8.count <= 255,
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              relativePath.utf8.count <= 4_096, rootID.utf8.count == 64,
              rootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidSelection }
        self.rpc = rpc; self.workspaceID = workspaceID; workspaceUUID = uuid
        self.connectionGeneration = connectionGeneration; self.path = path; self.rootID = rootID
        self.fileName = fileName; sourceByteCount = data.count; sourceData = data; self.relativePath = relativePath
        capable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesUpload)
        self.prepare = prepare; self.decode = decode
    }

    deinit { requestTask?.cancel() }

    /// Starts at most once for this instance; no state permits retrying the same payload.
    public func start() {
        guard active, !started else { return }
        started = true
        guard capable else { sourceData = nil; state = .failed(.unsupported); return }
        guard let data = sourceData else { return }
        state = .preparing
        let input = MobileWorkspaceFileUploadCodec.Input(id: requestID, workspaceID: workspaceID, path: path,
                                                        rootID: rootID, fileName: fileName, data: data)
        let token = token, rpc = rpc, prepare = prepare, decode = decode
        requestTask = Task { [weak self] in
            do {
                let prepared = try await prepare(input)
                guard let self, self.active, self.token == token else { return }
                self.sourceData = nil
                self.submissionStarted = true; self.state = .uploading
                let raw = try await rpc.sendRequest(prepared.body, timeoutNanoseconds: nil)
                guard self.active, self.token == token else { return }
                let receipt = try await decode(raw)
                guard self.active, self.token == token else { return }
                guard UUID(uuidString: receipt.workspaceID) == self.workspaceUUID,
                      receipt.path.utf8.elementsEqual(self.relativePath.utf8), receipt.rootID == self.rootID,
                      receipt.byteCount == self.sourceByteCount, receipt.sha256 == prepared.sha256 else {
                    throw Failure.invalidResponse
                }
                self.uploadedFile = receipt; self.state = .succeeded
            } catch {
                guard let self, self.active, self.token == token else { return }
                self.sourceData = nil; self.uploadedFile = nil
                if error is CancellationError { self.cancel() }
                else if case .rpcError("cancelled", _) = error as? MobileShellConnectionError { self.cancel() }
                else { self.state = .failed(Self.failure(error)) }
            }
        }
    }

    /// Retires a pending or unsubmitted selection, not a completed success or a server file.
    public func cancel() {
        guard active, state != .succeeded else { return }
        if case .failed = state, submissionStarted { return }
        active = false; token &+= 1; requestTask?.cancel(); requestTask = nil
        sourceData = nil; uploadedFile = nil; state = .cancelled
    }

    /// Permanently retires all local receipt/source state, even after success or cancellation.
    public func invalidate() {
        active = false; token &+= 1; requestTask?.cancel(); requestTask = nil
        sourceData = nil; uploadedFile = nil; state = .failed(.disconnected)
    }

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
            case "workspace_not_found", "workspace_unavailable", "directory_not_found": return .directoryUnavailable
            case "root_changed", "workspace_changed": return .directoryChanged
            case "file_changed": return .fileChanged
            case "file_already_exists": return .alreadyExists
            case "file_too_large": return .tooLarge
            case "integrity_mismatch": return .integrityMismatch
            case "not_a_directory": return .notDirectory
            case "admission_expired", "connection_closed", "disconnected": return .disconnected
            default: return .unavailable
            }
        default: return .unavailable
        }
    }
}
