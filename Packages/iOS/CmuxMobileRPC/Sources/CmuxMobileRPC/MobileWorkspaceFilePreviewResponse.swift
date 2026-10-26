public import Foundation

/// A strictly validated bounded raw-prefix response, without text interpretation.
///
/// ```swift
/// let preview = try MobileWorkspaceFilePreviewResponse.decode(responseData)
/// ```
public struct MobileWorkspaceFilePreviewResponse: Decodable, Sendable, Equatable {
    /// Original UUID spelling identifying the response workspace.
    public let workspaceID: String
    /// Original nonempty root-relative path.
    public let path: String
    /// Root consistency marker, not an authorization credential.
    public let rootID: String
    /// At most 262144 raw bytes decoded from canonical standard padded base64.
    public let data: Data
    /// Integral numeric wire count, exactly equal to the decoded data count.
    public let byteCount: Int
    /// Nonnegative integral numeric full-file size, not just the prefix size.
    public let totalBytes: Int64
    /// Whether the full file exceeds the raw prefix.
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", path, rootID = "root_id", encoded = "data_base64"
        case byteCount = "byte_count", totalBytes = "total_bytes", truncated
    }

    /// Requires all seven fields with strict types and mutually consistent sizes.
    /// - Parameter decoder: Decoder for a result object; unrelated future fields are allowed.
    /// - Throws: A decoding error for malformed, oversized or inconsistent wire values.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        path = try values.decode(String.self, forKey: .path)
        rootID = try values.decode(String.self, forKey: .rootID)
        let encoded = try values.decode(String.self, forKey: .encoded)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        totalBytes = try values.decode(Int64.self, forKey: .totalBytes)
        truncated = try values.decode(Bool.self, forKey: .truncated)
        guard UUID(uuidString: workspaceID) != nil, !path.isEmpty, path.utf8.count <= 4_096,
              !path.contains("\0"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }), rootID.utf8.count == 64,
              rootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              encoded.utf8.count <= 349_528,
              let decoded = Data(base64Encoded: encoded, options: []), decoded.count <= 262_144,
              decoded.base64EncodedString() == encoded, byteCount >= 0, totalBytes >= 0,
              byteCount == decoded.count, Int64(decoded.count) == min(totalBytes, 262_144),
              truncated == (totalBytes > Int64(decoded.count)) else { throw Self.invalid(decoder) }
        data = decoded
    }

    /// Decodes one RPC result without inventing defaults or repairing invalid fields.
    /// - Parameter data: Result JSON, already bounded by the existing RPC transport.
    /// - Returns: A validated raw-prefix value.
    /// - Throws: A decoding error for an invalid response.
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }

    private static func invalid(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid file preview"))
    }
}
