/// Safe upload failures without raw filesystem paths or errno messages.
public enum MobileWorkspaceFileUploadError: Error, Sendable, Equatable {
    /// A root marker or digest has invalid syntax.
    case invalidRequest
    /// Root, directory or filename syntax is invalid.
    case invalidPath
    /// The authorized root no longer matches its expected marker.
    case rootChanged
    /// The requested root or directory does not exist.
    case notFound
    /// A directory component is a symlink or not a directory.
    case notDirectory
    /// Filesystem permissions deny access.
    case permissionDenied
    /// A destination object already exists and was not replaced.
    case alreadyExists
    /// The complete payload exceeds 2 MiB.
    case tooLarge
    /// The supplied bytes do not match the expected SHA-256.
    case integrityMismatch
    /// Observable directory, staging or file identity/metadata changed before publication.
    case fileChanged
    /// The file could not be staged or published reliably.
    case unwritable
}
