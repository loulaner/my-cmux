import CmuxMobileHost
import Foundation

extension TerminalController {
    private enum MobileWorkspaceUploadGateError: Error, Sendable {
        case admissionExpired, policyDisabled, workspaceChanged
    }

    /// UI-owned workspace identity requires MainActor; the service hashes and writes off-main.
    /// Admission snapshots are not atomic with publication. A rejected response may follow a committed file.
    @MainActor
    func v2MobileWorkspaceFileUpload(
        params: [String: Any],
        executionContext: MobileHostRPCExecutionContext?,
        filesystemJobQuota: MobileTaskFilesystemJobQuota
    ) async -> V2CallResult {
        guard let context = executionContext, case .localDirect = context.authorization else {
            return Self.mobileWorkspaceUploadError("method_not_found")
        }
        do {
            try await Self.validateMobileWorkspaceUploadAdmission(context)
            guard let request = MobileWorkspaceFileUploadRequest(params: params) else {
                return Self.mobileWorkspaceUploadError("invalid_params")
            }
            let routingParams: [String: Any] = ["workspace_id": request.workspaceID.uuidString]
            guard let manager = v2ResolveTabManager(params: routingParams),
                  let workspace = v2ResolveWorkspace(params: routingParams, tabManager: manager) else {
                return Self.mobileWorkspaceUploadError("workspace_not_found")
            }
            guard !workspace.usesRemoteDirectoryProvenance else {
                return Self.mobileWorkspaceUploadError("unsupported_workspace")
            }
            guard let directory = workspace.presentedCurrentDirectory,
                  directory.hasPrefix("/"), !directory.contains("\0"), directory.utf8.count <= 4_096 else {
                return Self.mobileWorkspaceUploadError("workspace_unavailable")
            }
            guard filesystemJobQuota.acquire() else { return Self.mobileWorkspaceUploadError("busy") }
            defer { filesystemJobQuota.release() }
            let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
            let service = try MobileWorkspaceFileUploadService(rootDirectory: rootURL)
            // MainActor confines the non-Sendable Workspace and strongly retains its original identity.
            let beforeCommit: @MainActor @Sendable () async throws -> Void = {
                try await Self.validateMobileWorkspaceUploadAdmission(context)
                try self.validateMobileWorkspaceUploadScope(request.workspaceID, workspace: workspace, directory: directory)
            }
            let upload = try await service.write(
                relativeDirectoryPath: request.path, fileName: request.fileName, data: request.data,
                expectedRootID: request.rootID, expectedSHA256: request.sha256, beforeCommit: beforeCommit
            )
            try await Self.validateMobileWorkspaceUploadAdmission(context)
            try validateMobileWorkspaceUploadScope(request.workspaceID, workspace: workspace, directory: directory)
            guard upload.relativePath.utf8.elementsEqual(request.relativePath.utf8), upload.rootID == request.rootID,
                  upload.byteCount == request.data.count, upload.sha256 == request.sha256 else {
                return Self.mobileWorkspaceUploadError("unavailable")
            }
            var rootPath = rootURL.path(percentEncoded: false)
            while rootPath.count > 1 && rootPath.hasSuffix("/") { rootPath.removeLast() }
            let absolutePath = rootPath + (rootPath == "/" ? "" : "/") + upload.relativePath
            guard absolutePath.utf8.count <= 8_193 else { return Self.mobileWorkspaceUploadError("unavailable") }
            return .ok([
                "workspace_id": request.workspaceID.uuidString, "path": upload.relativePath,
                "root_id": upload.rootID, "byte_count": upload.byteCount, "sha256": upload.sha256,
                "absolute_path": absolutePath,
            ])
        } catch {
            if let error = Self.mobileFileTransferPolicyError() { return error }
            if case MobileWorkspaceUploadGateError.policyDisabled = error { return Self.mobileFileTransferDisabledResult }
            return Self.mobileWorkspaceUploadError(Self.mobileWorkspaceUploadErrorCode(error))
        }
    }

    @MainActor
    private static func validateMobileWorkspaceUploadAdmission(_ context: MobileHostRPCExecutionContext) async throws {
        if mobileFileTransferPolicyError() != nil { throw MobileWorkspaceUploadGateError.policyDisabled }
        try Task.checkCancellation()
        let allowed = await context.validateLocalDirectMutationAdmission()
        if mobileFileTransferPolicyError() != nil { throw MobileWorkspaceUploadGateError.policyDisabled }
        try Task.checkCancellation()
        guard allowed else { throw MobileWorkspaceUploadGateError.admissionExpired }
    }

    @MainActor
    private func validateMobileWorkspaceUploadScope(_ id: UUID, workspace: Workspace, directory: String) throws {
        let routingParams: [String: Any] = ["workspace_id": id.uuidString]
        guard let manager = v2ResolveTabManager(params: routingParams),
              let current = v2ResolveWorkspace(params: routingParams, tabManager: manager),
              current === workspace, !current.usesRemoteDirectoryProvenance,
              current.presentedCurrentDirectory == directory else { throw MobileWorkspaceUploadGateError.workspaceChanged }
    }

    private static func mobileWorkspaceUploadErrorCode(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let gate = error as? MobileWorkspaceUploadGateError {
            switch gate {
            case .admissionExpired: return "admission_expired"
            case .policyDisabled: return "file_transfer_disabled"
            case .workspaceChanged: return "workspace_changed"
            }
        }
        guard let error = error as? MobileWorkspaceFileUploadError else { return "unavailable" }
        switch error {
        case .invalidRequest, .invalidPath: return "invalid_params"
        case .rootChanged: return "root_changed"
        case .notFound: return "directory_not_found"
        case .notDirectory: return "not_a_directory"
        case .permissionDenied: return "permission_denied"
        case .alreadyExists: return "file_already_exists"
        case .tooLarge: return "file_too_large"
        case .integrityMismatch: return "integrity_mismatch"
        case .fileChanged: return "file_changed"
        case .unwritable: return "unavailable"
        }
    }

    private static func mobileWorkspaceUploadError(_ code: String) -> V2CallResult {
        let message: String
        if code == "invalid_params" {
            message = String(localized: "mobile.localDirect.files.error.invalidParams", defaultValue: "Invalid workspace file request")
        } else {
            message = String(localized: "mobile.localDirect.files.error.unavailable", defaultValue: "Workspace files are unavailable")
        }
        return .err(code: code, message: message, data: nil)
    }
}
