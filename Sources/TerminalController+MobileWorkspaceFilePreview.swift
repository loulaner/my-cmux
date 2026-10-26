import CmuxMobileHost
import Foundation

extension TerminalController {
    /// Resolves UI-owned workspace scope on MainActor; the service actor reads off-main.
    /// MDM and root checks are snapshots, not atomic authorization of the later transport write.
    @MainActor
    func v2MobileWorkspaceFilePreview(
        params: [String: Any],
        authorization: MobileHostConnectionAuthorizationContext?,
        filesystemJobQuota: MobileTaskFilesystemJobQuota
    ) async -> V2CallResult {
        guard case .localDirect = authorization else { return Self.mobileWorkspacePreviewError("method_not_found") }
        if let error = Self.mobileFileTransferPolicyError() { return error }
        guard let request = MobileWorkspaceFilePreviewRequest(params: params) else {
            return Self.mobileWorkspacePreviewError("invalid_params")
        }
        let routingParams: [String: Any] = ["workspace_id": request.workspaceID.uuidString]
        guard let manager = v2ResolveTabManager(params: routingParams),
              let workspace = v2ResolveWorkspace(params: routingParams, tabManager: manager) else {
            return Self.mobileWorkspacePreviewError("workspace_not_found")
        }
        guard !workspace.usesRemoteDirectoryProvenance else {
            return Self.mobileWorkspacePreviewError("unsupported_workspace")
        }
        guard let directory = workspace.presentedCurrentDirectory,
              directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4_096 else {
            return Self.mobileWorkspacePreviewError("workspace_unavailable")
        }
        guard filesystemJobQuota.acquire() else { return Self.mobileWorkspacePreviewError("busy") }
        defer { filesystemJobQuota.release() }
        do {
            let service = try MobileWorkspaceFilePreviewService(rootDirectory: URL(fileURLWithPath: directory, isDirectory: true))
            let preview = try await service.read(relativePath: request.path, expectedRootID: request.rootID)
            if let error = Self.mobileFileTransferPolicyError() { return error }
            try Task.checkCancellation()
            guard let currentManager = v2ResolveTabManager(params: routingParams),
                  let current = v2ResolveWorkspace(params: routingParams, tabManager: currentManager),
                  current === workspace, !current.usesRemoteDirectoryProvenance,
                  current.presentedCurrentDirectory == directory else {
                return Self.mobileWorkspacePreviewError("workspace_changed")
            }
            guard preview.relativePath.utf8.elementsEqual(request.path.utf8), preview.rootID == request.rootID,
                  preview.totalBytes >= 0,
                  Int64(preview.data.count) == min(preview.totalBytes, 262_144),
                  preview.truncated == (preview.totalBytes > Int64(preview.data.count)) else {
                return Self.mobileWorkspacePreviewError("unavailable")
            }
            return .ok([
                "workspace_id": request.workspaceID.uuidString, "path": preview.relativePath,
                "root_id": preview.rootID, "data_base64": preview.data.base64EncodedString(),
                "byte_count": preview.data.count, "total_bytes": preview.totalBytes, "truncated": preview.truncated,
            ])
        } catch {
            if let error = Self.mobileFileTransferPolicyError() { return error }
            return Self.mobileWorkspacePreviewError(Self.mobileWorkspacePreviewErrorCode(error))
        }
    }

    private static func mobileWorkspacePreviewErrorCode(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let error = error as? MobileWorkspaceFilePreviewError else { return "unavailable" }
        switch error {
        case .invalidRequest, .invalidPath: return "invalid_params"
        case .rootChanged: return "root_changed"
        case .notFound: return "file_not_found"
        case .notRegularFile: return "not_a_file"
        case .permissionDenied: return "permission_denied"
        case .fileChanged: return "file_changed"
        case .unreadable: return "unavailable"
        }
    }

    private static func mobileWorkspacePreviewError(_ code: String) -> V2CallResult {
        let message: String
        if code == "invalid_params" {
            message = String(localized: "mobile.localDirect.files.error.invalidParams", defaultValue: "Invalid workspace file request")
        } else {
            message = String(localized: "mobile.localDirect.files.error.unavailable", defaultValue: "Workspace files are unavailable")
        }
        return .err(code: code, message: message, data: nil)
    }
}
