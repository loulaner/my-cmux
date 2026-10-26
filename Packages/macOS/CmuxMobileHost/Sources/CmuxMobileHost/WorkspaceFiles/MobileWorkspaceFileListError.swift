/// Safe listing failures without filesystem paths, errno values, or raw messages.
public enum MobileWorkspaceFileListError: Error, Sendable, Equatable {
    /// The pagination arguments are outside the supported range.
    case invalidRequest
    /// The root URL or relative path has an invalid format.
    case invalidPath
    /// The requested directory does not exist.
    case notFound
    /// A traversal component is not a directory or is a symbolic link.
    case notDirectory
    /// The operating system denied access.
    case permissionDenied
    /// Enumeration or metadata could not be read reliably.
    case unreadable
    /// The directory exceeded the bounded enumeration budget.
    case tooManyEntries
}
