public import Foundation

/// A bounded raw prefix of a regular file, not interpreted content or an atomic snapshot.
public struct MobileWorkspaceFilePreview: Sendable, Equatable {
    /// Original validated root-relative file path.
    public let relativePath: String
    /// Consistency marker for the opened root, never an authorization credential.
    public let rootID: String
    /// Raw bytes, including binary data or an incomplete trailing UTF-8 sequence.
    public let data: Data
    /// Full file size observed consistently before and after reading the same descriptor.
    public let totalBytes: Int64
    /// Whether the file contains more bytes than this bounded prefix.
    public let truncated: Bool
}
