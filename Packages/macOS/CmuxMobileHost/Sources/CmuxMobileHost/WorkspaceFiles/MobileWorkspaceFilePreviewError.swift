/// Safe preview failures without raw filesystem paths, errno values or messages.
public enum MobileWorkspaceFilePreviewError: Error, Sendable, Equatable {
    /// The expected root marker is not a 64-character lowercase hexadecimal value.
    case invalidRequest
    /// The root URL or relative file path has invalid syntax.
    case invalidPath
    /// The opened root no longer matches the caller's consistency marker.
    case rootChanged
    /// The requested root, parent or file does not exist.
    case notFound
    /// A component is a link or non-directory, or the leaf is not a regular file.
    case notRegularFile
    /// Filesystem permissions denied access.
    case permissionDenied
    /// Observable file metadata or the expected byte count changed during reading.
    case fileChanged
    /// The file could not be read reliably.
    case unreadable
}
