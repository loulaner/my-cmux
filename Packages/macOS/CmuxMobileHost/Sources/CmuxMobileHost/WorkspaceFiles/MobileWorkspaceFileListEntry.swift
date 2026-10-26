/// Metadata for one immediate child, without an absolute path or link target.
public struct MobileWorkspaceFileListEntry: Sendable, Equatable {
    /// The entry's own filesystem kind, without following symbolic links.
    public enum Kind: String, Sendable, Equatable {
        /// A regular file.
        case file
        /// A directory.
        case directory
        /// A symbolic link, including a dangling link.
        case symbolicLink
        /// Any other filesystem object, including a FIFO.
        case other
    }
    /// The original single-component UTF-8 name.
    public let name: String
    /// The original path relative to the caller-authorized root.
    public let relativePath: String
    /// The entry's own kind.
    public let kind: Kind
    /// Nonnegative size for regular files only; all other kinds have no size.
    public let byteCount: Int64?
}
