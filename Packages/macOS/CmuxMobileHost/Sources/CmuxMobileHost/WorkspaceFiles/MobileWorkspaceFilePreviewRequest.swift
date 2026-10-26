public import Foundation

/// Validates a fixed, bounded raw-prefix preview request without filesystem access.
///
/// ```swift
/// let request = MobileWorkspaceFilePreviewRequest(params: [
///     "workspace_id": workspaceID.uuidString, "path": "README.md", "root_id": rootID
/// ])
/// ```
public struct MobileWorkspaceFilePreviewRequest: Sendable {
    /// Explicit workspace identity, never a selected-workspace fallback.
    public let workspaceID: UUID
    /// Unmodified nonempty root-relative path, without decoding or normalization.
    public let path: String
    /// Root consistency marker, not an authorization credential.
    public let rootID: String

    /// Accepts exactly the three required fields and no caller-supplied trust or size controls.
    /// - Parameter params: Untrusted JSON-compatible RPC parameters.
    /// - Returns: `nil` for missing, extra, malformed or incorrectly typed fields.
    public init?(params: [String: Any]) {
        guard Set(params.keys) == ["workspace_id", "path", "root_id"],
              let rawID = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: rawID),
              let path = params["path"] as? String, !path.isEmpty,
              path.utf8.count <= 4_096, !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }),
              let rootID = params["root_id"] as? String, rootID.utf8.count == 64,
              rootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.workspaceID = workspaceID
        self.path = path
        self.rootID = rootID
    }
}
