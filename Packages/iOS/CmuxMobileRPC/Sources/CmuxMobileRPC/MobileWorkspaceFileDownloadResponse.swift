import CryptoKit
public import Foundation

/// A strictly validated complete bounded file response with independently verified byte integrity.
///
/// ```swift
/// let download = try MobileWorkspaceFileDownloadResponse.decode(responseData)
/// ```
public struct MobileWorkspaceFileDownloadResponse: Decodable, Sendable, Equatable {
    /// Original UUID spelling identifying the response workspace.
    public let workspaceID: String
    /// Original nonempty root-relative path.
    public let path: String
    /// Root consistency marker, not an authorization credential.
    public let rootID: String
    /// At most 2097152 raw bytes decoded from canonical standard padded base64.
    public let data: Data
    /// Integral numeric wire count, exactly equal to the decoded data count.
    public let byteCount: Int
    /// SHA-256 of the returned bytes; integrity information, not authentication or authorization.
    public let sha256: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", path, rootID = "root_id", encoded = "data_base64"
        case byteCount = "byte_count", sha256
    }

    /// Requires all six fields with strict types and mutually consistent sizes.
    /// - Parameter decoder: Decoder for a result object; unrelated future fields are allowed.
    /// - Throws: A decoding error for malformed, oversized or inconsistent wire values.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        path = try values.decode(String.self, forKey: .path)
        rootID = try values.decode(String.self, forKey: .rootID)
        let encoded = try values.decode(String.self, forKey: .encoded)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        sha256 = try values.decode(String.self, forKey: .sha256)
        guard UUID(uuidString: workspaceID) != nil, !path.isEmpty, path.utf8.count <= 4_096,
              !path.contains("\0"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }), rootID.utf8.count == 64,
              rootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              encoded.utf8.count <= 2_796_204,
              let decoded = Data(base64Encoded: encoded, options: []), decoded.count <= 2_097_152,
              decoded.base64EncodedString() == encoded, byteCount >= 0, byteCount == decoded.count,
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Self.invalid(decoder) }
        let actualDigest = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == sha256 else { throw Self.invalid(decoder) }
        data = decoded
    }

    /// Decodes one RPC result without inventing defaults or repairing invalid fields.
    /// - Parameter data: Result JSON, already bounded by the existing RPC transport.
    /// - Returns: A validated complete-file value.
    /// - Throws: A decoding error for an invalid response.
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }

    private static func invalid(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid file download"))
    }
}
