/// A complete newly published workspace file, without staging or absolute paths.
public struct MobileWorkspaceFileUpload: Sendable, Equatable {
    /// Original literal path relative to the authorized root.
    public let relativePath: String
    /// Root consistency marker, not an authorization credential.
    public let rootID: String
    /// Exact complete byte count, including zero for an empty file.
    public let byteCount: Int
    /// Independently verified lowercase SHA-256 of the supplied bytes.
    public let sha256: String
}
