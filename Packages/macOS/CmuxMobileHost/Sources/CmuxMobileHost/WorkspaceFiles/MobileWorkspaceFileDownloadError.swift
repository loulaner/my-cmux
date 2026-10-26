/// Safe whole-file read failures, without absolute paths, errno values or raw messages.
public enum MobileWorkspaceFileDownloadError: Error, Sendable, Equatable {
    /// The expected root marker is not 64 lowercase hexadecimal ASCII characters.
    case invalidRequest
    /// Root URL or relative file path syntax is invalid.
    case invalidPath
    /// The opened root differs from the expected consistency marker.
    case rootChanged
    /// The requested root, parent or file does not exist.
    case notFound
    /// A component is a link or non-directory, or the leaf is not a regular file.
    case notRegularFile
    /// Filesystem permissions denied access.
    case permissionDenied
    /// Observable metadata or the expected complete byte count changed while reading.
    case fileChanged
    /// The regular file exceeds the fixed 2 MiB whole-file limit.
    case tooLarge
    /// The file could not be read reliably.
    case unreadable
}
