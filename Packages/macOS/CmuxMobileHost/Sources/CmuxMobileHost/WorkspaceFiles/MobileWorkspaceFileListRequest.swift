import CoreFoundation
public import Foundation

/// Validates the metadata-only Direct file-list request without filesystem access.
///
/// ```swift
/// let request = MobileWorkspaceFileListRequest(params: ["workspace_id": workspaceID.uuidString])
/// ```
public struct MobileWorkspaceFileListRequest: Sendable {
    /// The explicit workspace identity; never a selected-workspace fallback.
    public let workspaceID: UUID
    /// The unmodified relative path, defaulting to empty for the workspace root.
    public let path: String
    /// A nonnegative offset, defaulting to zero; the service clamps it safely.
    public let offset: Int
    /// Page size from 1 through 100, defaulting to the supported maximum.
    public let limit: Int

    /// Parses only the four allowed fields, rejecting nulls, extra keys and booleans as integers.
    /// - Parameter params: Untrusted RPC values; no trust context may be supplied here.
    /// - Returns: `nil` when the request does not satisfy the strict value contract.
    public init?(params: [String: Any]) {
        guard Set(params.keys).isSubset(of: ["workspace_id", "path", "offset", "limit"]),
              let rawID = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: rawID) else { return nil }
        let path: String
        if let value = params["path"] {
            guard let value = value as? String else { return nil }
            path = value
        } else { path = "" }
        guard path.utf8.count <= 4_096, !path.contains("\0"),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }),
              let offset = Self.integer(params["offset"], defaultValue: 0), offset >= 0,
              let limit = Self.integer(params["limit"], defaultValue: 100), (1...100).contains(limit) else { return nil }
        self.workspaceID = workspaceID
        self.path = path
        self.offset = offset
        self.limit = limit
    }

    private static func integer(_ value: Any?, defaultValue: Int) -> Int? {
        guard let value else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = value as? Int else { return nil }
        return integer
    }
}
