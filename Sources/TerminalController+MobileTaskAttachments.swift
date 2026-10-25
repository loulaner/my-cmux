import CmuxCloud
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// The refusal for a mobile file transfer already denied by policy.
    static var mobileFileTransferDisabledResult: V2CallResult {
        return .err(code: "file_transfer_disabled", message: ManagedFileTransferPolicy.disabledMessage, data: nil)
    }

    /// Returns the shared refusal before any mobile file transfer work begins.
    static func mobileFileTransferPolicyError(
        isDisabled: Bool = ManagedFileTransferPolicy.isDisabled
    ) -> V2CallResult? {
        guard isDisabled else { return nil }
        return mobileFileTransferDisabledResult
    }

    /// Handles one `mobile.task.attachment.upload` chunk.
    func v2MobileTaskAttachmentUpload(params: [String: Any]) -> V2CallResult {
        if let error = Self.mobileFileTransferPolicyError() { return error }
        guard Self.mobileTaskComposerFeatureEnabled else {
            return Self.mobileTaskComposerDisabledResult
        }
        guard let operationIDString = v2RawString(params, "operation_id"),
              let operationID = UUID(uuidString: operationIDString),
              let uploadIDString = v2RawString(params, "upload_id"),
              let uploadID = UUID(uuidString: uploadIDString),
              let fileName = v2RawString(params, "file_name"),
              let totalBytes = v2Int(params, "total_bytes"),
              let offset = v2Int(params, "offset"),
              let dataBase64 = v2RawString(params, "data_b64"),
              let isLast = params["last"] as? Bool else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid attachment upload parameters",
                data: nil
            )
        }
        let store = MobileTaskAttachmentStore(
            rootURL: MobileTaskAttachmentStore.defaultRootURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            now: Date(),
            fileManager: FileManager.default
        )
        do {
            let result = try store.upload(MobileTaskAttachmentUploadRequest(
                operationID: operationID,
                uploadID: uploadID,
                fileName: fileName,
                totalBytes: totalBytes,
                offset: offset,
                dataBase64: dataBase64,
                isLast: isLast
            ))
            var payload: [String: Any] = [
                "received_bytes": result.receivedBytes,
            ]
            if let path = result.path {
                payload["path"] = path
            }
            return .ok(payload)
        } catch let error as MobileTaskAttachmentStoreError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(
                code: "internal_error",
                message: "Could not store task attachment",
                data: nil
            )
        }
    }
}
