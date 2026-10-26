import CoreFoundation
public import Foundation

/// A strict complete-file upload request, parsed without I/O or digest computation.
///
/// ```swift
/// let request = MobileWorkspaceFileUploadRequest(params: rpcParameters)
/// ```
public struct MobileWorkspaceFileUploadRequest: Sendable {
    /// Explicit workspace identity, never a selected-workspace fallback.
    public let workspaceID: UUID
    /// Literal target directory relative to the workspace root; empty means root.
    public let path: String
    /// Required lowercase root consistency marker, not an authorization credential.
    public let rootID: String
    /// Literal safe leaf, at most 255 UTF-8 bytes.
    public let fileName: String
    /// Complete decoded bytes, at most 2 MiB, including an empty file.
    public let data: Data
    /// Lowercase expected digest; the service independently hashes the actual bytes.
    public let sha256: String
    /// Literal complete root-relative destination, at most 4096 UTF-8 bytes.
    public let relativePath: String

    /// Parses exactly seven required fields with canonical base64 and an exact byte count.
    /// - Parameter params: Untrusted values; no trust, overwrite or absolute-path options.
    /// - Returns: `nil` for an invalid schema, value, encoding or size.
    public init?(params: [String: Any]) {
        guard Set(params.keys) == ["workspace_id", "path", "root_id", "file_name", "data_base64", "byte_count", "sha256"],
              let rawID = params["workspace_id"] as? String,
              let path = params["path"] as? String,
              let directory = MobileWorkspaceFileListRequest(params: ["workspace_id": rawID, "path": path]),
              let rootID = params["root_id"] as? String, Self.validHex(rootID),
              let sha256 = params["sha256"] as? String, Self.validHex(sha256),
              let fileName = params["file_name"] as? String,
              !fileName.isEmpty, fileName != ".", fileName != "..", fileName.utf8.count <= 255,
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let count = params["byte_count"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
              let byteCount = params["byte_count"] as? Int, (0...2_097_152).contains(byteCount),
              let encoded = params["data_base64"] as? String, encoded.utf8.count <= 2_796_204,
              let data = Data(base64Encoded: encoded, options: []), data.count == byteCount,
              data.count <= 2_097_152, data.base64EncodedString() == encoded else { return nil }
        let relativePath = path.isEmpty ? fileName : path + "/" + fileName
        guard relativePath.utf8.count <= 4_096 else { return nil }
        self.workspaceID = directory.workspaceID
        self.path = path
        self.rootID = rootID
        self.fileName = fileName
        self.data = data
        self.sha256 = sha256
        self.relativePath = relativePath
    }

    private static func validHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
