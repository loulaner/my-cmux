public import Foundation

/// Complete raw file bytes within the download limit, never a truncated prefix or atomic snapshot.
public struct MobileWorkspaceFileDownload: Sendable, Equatable {
    /// Original validated root-relative file path.
    public let relativePath: String
    /// Root consistency marker, not an authorization credential.
    public let rootID: String
    /// Complete raw bytes; binary data is preserved without interpretation.
    public let data: Data
    /// Lowercase hexadecimal SHA-256 of exactly ``data``; integrity information, not authentication.
    public let sha256: String
    /// Exact number of returned file bytes.
    public var byteCount: Int { data.count }
}
