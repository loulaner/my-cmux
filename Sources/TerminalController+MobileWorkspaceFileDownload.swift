import CmuxMobileHost
import Foundation

extension TerminalController {
    /// Resolves UI-owned workspace scope on MainActor; the service actor reads off-main.
    /// MDM and root checks are snapshots, not atomic authorization of the later transport write.
    @MainActor
    func v2MobileWorkspaceFileDownload(
        params: [String: Any],
        authorization: MobileHostConnectionAuthorizationContext?,
        filesystemJobQuota: MobileTaskFilesystemJobQuota
    ) async -> V2CallResult {
        guard case .localDirect = authorization else { return Self.mobileWorkspaceDownloadError("method_not_found") }
        if let error = Self.mobileFileTransferPolicyError() { return error }
        guard let request = MobileWorkspaceFilePreviewRequest(params: params) else {
            return Self.mobileWorkspaceDownloadError("invalid_params")
        }
        let routingParams: [String: Any] = ["workspace_id": request.workspaceID.uuidString]
        guard let manager = v2ResolveTabManager(params: routingParams),
              let workspace = v2ResolveWorkspace(params: routingParams, tabManager: manager) else {
            return Self.mobileWorkspaceDownloadError("workspace_not_found")
        }
        guard !workspace.usesRemoteDirectoryProvenance else {
            return Self.mobileWorkspaceDownloadError("unsupported_workspace")
        }
        guard let directory = workspace.presentedCurrentDirectory,
              directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4_096 else {
            return Self.mobileWorkspaceDownloadError("workspace_unavailable")
        }
        guard filesystemJobQuota.acquire() else { return Self.mobileWorkspaceDownloadError("busy") }
        defer { filesystemJobQuota.release() }
        do {
            let service = try MobileWorkspaceFileDownloadService(rootDirectory: URL(fileURLWithPath: directory, isDirectory: true))
            let download = try await service.read(relativePath: request.path, expectedRootID: request.rootID)
            if let error = Self.mobileFileTransferPolicyError() { return error }
            try Task.checkCancellation()
            guard let currentManager = v2ResolveTabManager(params: routingParams),
                  let current = v2ResolveWorkspace(params: routingParams, tabManager: currentManager),
                  current === workspace, !current.usesRemoteDirectoryProvenance,
                  current.presentedCurrentDirectory == directory else {
                return Self.mobileWorkspaceDownloadError("workspace_changed")
            }
            // The service hashes actual complete bytes; this boundary validates digest format only.
            guard download.relativePath.utf8.elementsEqual(request.path.utf8), download.rootID == request.rootID,
                  download.data.count <= MobileWorkspaceFileDownloadService.maximumDownloadBytes,
                  download.sha256.utf8.count == 64,
                  download.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return Self.mobileWorkspaceDownloadError("unavailable")
            }
            return .ok([
                "workspace_id": request.workspaceID.uuidString, "path": download.relativePath,
                "root_id": download.rootID, "data_base64": download.data.base64EncodedString(),
                "byte_count": download.data.count, "sha256": download.sha256,
            ])
        } catch {
            if let error = Self.mobileFileTransferPolicyError() { return error }
            return Self.mobileWorkspaceDownloadError(Self.mobileWorkspaceDownloadErrorCode(error))
        }
    }

    private static func mobileWorkspaceDownloadErrorCode(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? MobileWorkspaceFileDownloadError else { return "unavailable" }
        switch error {
        case .invalidRequest, .invalidPath: return "invalid_params"
        case .rootChanged: return "root_changed"
        case .notFound: return "file_not_found"
        case .notRegularFile: return "not_a_file"
        case .permissionDenied: return "permission_denied"
        case .fileChanged: return "file_changed"
        case .tooLarge: return "file_too_large"
        case .unreadable: return "unavailable"
        }
    }

    private static func mobileWorkspaceDownloadError(_ code: String) -> V2CallResult {
        let message: String
        if code == "invalid_params" {
            message = String(localized: "mobile.localDirect.files.error.invalidParams", defaultValue: "Invalid workspace file request")
        } else {
            message = String(localized: "mobile.localDirect.files.error.unavailable", defaultValue: "Workspace files are unavailable")
        }
        return .err(code: code, message: message, data: nil)
    }
}
