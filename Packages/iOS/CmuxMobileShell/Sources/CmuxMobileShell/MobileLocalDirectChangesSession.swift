import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import Observation

/// Read-only changes for one immutable workspace on an already admitted shared connection.
/// Owns only its requests: never connects, disconnects, subscribes, or retries automatically.
@MainActor @Observable
public final class MobileLocalDirectChangesSession {
    /// Safe failures without server messages, credentials, or raw errors.
    public enum Failure: Error, Equatable, Sendable {
        case invalidSelection, unsupported, notRepository, permissionDenied, invalidResponse, unavailable, disconnected
    }
    /// Independent readiness of a list or selected diff.
    public enum LoadState: Equatable, Sendable { case idle, loading, ready, failed(Failure) }
    /// Original workspace string used on the wire; responses compare UUID identity.
    public let workspaceID: String
    /// Parent connection generation; a new connection requires a new session.
    public let connectionGeneration: UInt64
    /// Last validated list, cleared before every refresh.
    public private(set) var filesResponse: MobileWorkspaceChangedFilesResponse?
    /// Last validated selected-file diff.
    public private(set) var diffResponse: MobileWorkspaceFileDiffResponse?
    /// Exact path from the current validated list.
    public private(set) var selectedPath: String?
    /// Current list readiness.
    public private(set) var filesState: LoadState = .idle
    /// Current diff readiness.
    public private(set) var diffState: LoadState = .idle
    @ObservationIgnored private let rpc: any MobileSyncing
    @ObservationIgnored private let workspaceUUID: UUID
    @ObservationIgnored private let capable: Bool
    @ObservationIgnored private var active = true
    @ObservationIgnored private var listToken: UInt64 = 0
    @ObservationIgnored private var diffToken: UInt64 = 0
    // Internal read-only handles let tests await actual completion, including ignored cancellation.
    @ObservationIgnored private(set) var listTask: Task<Void, Never>?
    @ObservationIgnored private(set) var diffTask: Task<Void, Never>?

    /// Stores the existing connection and selection without sending any requests.
    /// - Parameters:
    ///   - rpc: The controller-owned shared RPC seam.
    ///   - workspaceID: UUID string identifying the verified workspace.
    ///   - connectionGeneration: Immutable parent connection generation.
    ///   - capabilities: Capabilities advertised on this connection.
    /// - Throws: `Failure.invalidSelection` if the workspace is not a UUID.
    public init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64, capabilities: Set<String>) throws {
        guard let uuid = UUID(uuidString: workspaceID) else { throw Failure.invalidSelection }
        self.rpc = rpc
        self.workspaceID = workspaceID
        workspaceUUID = uuid
        self.connectionGeneration = connectionGeneration
        capable = capabilities.contains(CmxLocalDirectCapabilities.workspaceChangesRead)
    }

    deinit {
        listTask?.cancel()
        diffTask?.cancel()
    }

    /// Starts one list read, discarding the previous list, selection, and diff.
    public func refresh() {
        guard active else { return }
        listTask?.cancel(); listToken &+= 1
        clearDiff()
        filesResponse = nil
        guard capable else {
            filesState = .failed(.unsupported); diffState = .failed(.unsupported)
            return
        }
        filesState = .loading
        let token = listToken
        let rpc = rpc
        do {
            let request = try Self.request("mobile.workspace.changes.files", params: ["workspace_id": workspaceID])
            listTask = Task { [weak self] in
                guard let active = self?.active, active, self?.listToken == token else { return }
                do {
                    let data = try await rpc.sendRequest(request, timeoutNanoseconds: nil)
                    guard let self, self.active, self.listToken == token else { return }
                    self.filesResponse = try self.validatedFiles(data)
                    self.filesState = .ready
                } catch {
                    guard let self, self.active, self.listToken == token else { return }
                    self.filesState = error is CancellationError ? .idle : .failed(Self.failure(error))
                }
            }
        } catch { filesState = .failed(.unavailable) }
    }

    /// Starts one bounded diff read only for an exact path in the current list.
    /// - Parameter path: Unmodified repository-relative path from the validated response.
    public func selectFile(path: String) {
        guard active else { return }
        clearDiff()
        guard capable else { diffState = .failed(.unsupported); return }
        guard filesState == .ready, filesResponse?.files.contains(where: { $0.path == path }) == true else {
            diffState = .failed(.invalidSelection)
            return
        }
        selectedPath = path
        diffState = .loading
        let token = diffToken, list = listToken
        let rpc = rpc
        do {
            let request = try Self.request("mobile.workspace.changes.file_diff", params: [
                "workspace_id": workspaceID, "path": path, "max_lines": 6000,
            ])
            diffTask = Task { [weak self] in
                guard self?.active == true, self?.diffToken == token, self?.listToken == list else { return }
                do {
                    let data = try await rpc.sendRequest(request, timeoutNanoseconds: nil)
                    guard let self, self.active, self.diffToken == token, self.listToken == list else { return }
                    self.diffResponse = try Self.validatedDiff(data, path: path)
                    self.diffState = .ready
                } catch {
                    guard let self, self.active, self.diffToken == token, self.listToken == list else { return }
                    self.diffState = error is CancellationError ? .idle : .failed(Self.failure(error))
                }
            }
        } catch { diffState = .failed(.unavailable) }
    }

    /// Permanently retires this session without disconnecting the shared RPC connection.
    public func invalidate() {
        guard active else { return }
        active = false
        listTask?.cancel(); listTask = nil; listToken &+= 1
        clearDiff()
        filesResponse = nil
        filesState = .failed(.disconnected); diffState = .failed(.disconnected)
    }

    private func clearDiff() {
        diffTask?.cancel(); diffTask = nil; diffToken &+= 1
        diffResponse = nil; selectedPath = nil; diffState = .idle
    }

    private static func request(_ method: String, params: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func validatedFiles(_ data: Data) throws -> MobileWorkspaceChangedFilesResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspace = object["workspace_id"] as? String, UUID(uuidString: workspace) == workspaceUUID,
              let root = object["repo_root"] as? String, root.hasPrefix("/"), !root.contains("\0"),
              let files = object["files"] as? [[String: Any]] else { throw Failure.invalidResponse }
        var paths = Set<String>()
        for file in files {
            guard let path = file["path"] as? String, Self.validPath(path), paths.insert(path).inserted else {
                throw Failure.invalidResponse
            }
            if let old = file["old_path"], !(old is NSNull) {
                guard let old = old as? String, Self.validPath(old) else { throw Failure.invalidResponse }
            }
        }
        guard let response = try? MobileWorkspaceChangedFilesResponse.decode(data) else { throw Failure.invalidResponse }
        return response
    }

    private static func validatedDiff(_ data: Data, path: String) throws -> MobileWorkspaceFileDiffResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["path"] as? String == path, object["unified_diff"] is String,
              let response = try? MobileWorkspaceFileDiffResponse.decode(data) else { throw Failure.invalidResponse }
        return response
    }

    private static func failure(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is DecodingError { return .invalidResponse }
        guard let connection = error as? MobileShellConnectionError else { return .unavailable }
        switch connection {
        case .invalidResponse: return .invalidResponse
        case .connectionClosed: return .disconnected
        case let .rpcError(code, _):
            switch code {
            case "method_not_found", "capability_disabled": return .unsupported
            case "not_a_repo": return .notRepository
            case "file_transfer_disabled", "forbidden", "permission_denied": return .permissionDenied
            case "connection_closed", "disconnected": return .disconnected
            default: return .unavailable
            }
        default: return .unavailable
        }
    }
}
