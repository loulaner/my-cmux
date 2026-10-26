import CmuxMobileRPC
import CryptoKit
import Foundation

/// Bounded hashing, encoding and acknowledgement decoding on an actor distinct from MainActor.
actor MobileWorkspaceFileUploadCodec {
    struct Input: Sendable {
        let id: UUID
        let workspaceID: String
        let path: String
        let rootID: String
        let fileName: String
        let data: Data
    }
    struct Prepared: Sendable {
        let body: Data
        let sha256: String
        let byteCount: Int
    }

    /// The caller validates the selection; no I/O or connection ownership is involved.
    func prepare(_ input: Input) throws -> Prepared {
        try Task.checkCancellation()
        guard input.data.count <= 2_097_152 else { throw MobileShellConnectionError.invalidResponse }
        let digest = SHA256.hash(data: input.data).map { String(format: "%02x", $0) }.joined()
        let body = try JSONSerialization.data(withJSONObject: [
            "id": input.id.uuidString, "method": "mobile.workspace.files.upload",
            "params": ["workspace_id": input.workspaceID, "path": input.path, "root_id": input.rootID,
                       "file_name": input.fileName, "data_base64": input.data.base64EncodedString(),
                       "byte_count": input.data.count, "sha256": digest],
        ])
        guard body.count <= 8_388_608 else { throw MobileShellConnectionError.invalidResponse }
        try Task.checkCancellation()
        return Prepared(body: body, sha256: digest, byteCount: input.data.count)
    }

    func decode(_ data: Data) throws -> MobileWorkspaceFileUploadResponse {
        try Task.checkCancellation()
        let response = try MobileWorkspaceFileUploadResponse.decode(data)
        try Task.checkCancellation()
        return response
    }
}
