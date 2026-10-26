import CmuxMobileHost
import Foundation

extension TerminalController {
    /// UI-owned workspace resolution and post-await scope checks require MainActor;
    /// the filesystem actor performs bounded directory I/O off-main.
    @MainActor
    func v2MobileWorkspaceFilesList(
        params: [String: Any],
        authorization: MobileHostConnectionAuthorizationContext?,
        filesystemJobQuota: MobileTaskFilesystemJobQuota
    ) async -> V2CallResult {
        guard case .localDirect = authorization else { return Self.mobileWorkspaceFilesError("method_not_found") }
        if let error = Self.mobileFileTransferPolicyError() { return error }
        guard let request = MobileWorkspaceFileListRequest(params: params) else {
            return Self.mobileWorkspaceFilesError("invalid_params")
        }
        let routingParams: [String: Any] = ["workspace_id": request.workspaceID.uuidString]
        guard let manager = v2ResolveTabManager(params: routingParams),
              let workspace = v2ResolveWorkspace(params: routingParams, tabManager: manager) else {
            return Self.mobileWorkspaceFilesError("workspace_not_found")
        }
        guard !workspace.usesRemoteDirectoryProvenance else {
            return Self.mobileWorkspaceFilesError("unsupported_workspace")
        }
        guard let directory = workspace.presentedCurrentDirectory,
              directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4_096 else {
            return Self.mobileWorkspaceFilesError("workspace_unavailable")
        }
        guard filesystemJobQuota.acquire() else { return Self.mobileWorkspaceFilesError("busy") }
        defer { filesystemJobQuota.release() }
        do {
            let service = try MobileWorkspaceFileListService(rootDirectory: URL(fileURLWithPath: directory, isDirectory: true))
            let page = try await service.list(relativePath: request.path, offset: request.offset, limit: request.limit)
            if let error = Self.mobileFileTransferPolicyError() { return error }
            try Task.checkCancellation()
            guard let currentManager = v2ResolveTabManager(params: routingParams),
                  let current = v2ResolveWorkspace(params: routingParams, tabManager: currentManager),
                  current === workspace, !current.usesRemoteDirectoryProvenance,
                  current.presentedCurrentDirectory == directory else {
                return Self.mobileWorkspaceFilesError("workspace_changed")
            }
            let entries: [[String: Any]] = page.entries.map {
                ["name": $0.name, "path": $0.relativePath, "kind": $0.kind.rawValue,
                 "size": $0.byteCount.map { $0 as Any } ?? NSNull()]
            }
            return .ok([
                "workspace_id": request.workspaceID.uuidString, "path": page.relativePath,
                "parent_path": page.parentRelativePath.map { $0 as Any } ?? NSNull(), "entries": entries,
                "offset": page.offset, "limit": page.limit, "total_count": page.totalCount,
                "next_offset": page.nextOffset.map { $0 as Any } ?? NSNull(),
            ])
        } catch {
            if let error = Self.mobileFileTransferPolicyError() { return error }
            return Self.mobileWorkspaceFilesError(Self.mobileWorkspaceFilesErrorCode(error))
        }
    }

    private static func mobileWorkspaceFilesErrorCode(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? MobileWorkspaceFileListError else { return "unavailable" }
        switch error {
        case .invalidRequest, .invalidPath: return "invalid_params"
        case .notFound: return "directory_not_found"
        case .notDirectory: return "not_a_directory"
        case .permissionDenied: return "permission_denied"
        case .tooManyEntries: return "limit_exceeded"
        case .unreadable: return "unavailable"
        }
    }

    private static func mobileWorkspaceFilesError(_ code: String) -> V2CallResult {
        let message: String
        switch code {
        case "invalid_params":
            message = String(localized: "mobile.localDirect.files.error.invalidParams", defaultValue: "Invalid workspace file request")
        case "limit_exceeded":
            message = String(localized: "mobile.localDirect.files.error.tooManyEntries", defaultValue: "Directory contains too many entries")
        default:
            message = String(localized: "mobile.localDirect.files.error.unavailable", defaultValue: "Workspace files are unavailable")
        }
        return .err(code: code, message: message, data: nil)
    }
}
