/// A page from one bounded directory enumeration, not a stable cross-request cursor.
public struct MobileWorkspaceFileListPage: Sendable, Equatable {
    /// The requested root-relative directory; empty means the root.
    public let relativePath: String
    /// The root-relative parent, or `nil` at the root.
    public let parentRelativePath: String?
    /// Immediate children sorted by UTF-8 name bytes.
    public let entries: [MobileWorkspaceFileListEntry]
    /// The requested offset clamped to the enumerated count.
    public let offset: Int
    /// The accepted page size.
    public let limit: Int
    /// The number of surviving entries in this enumeration.
    public let totalCount: Int
    /// The next offset when more entries remain, otherwise `nil`.
    public let nextOffset: Int?
}
