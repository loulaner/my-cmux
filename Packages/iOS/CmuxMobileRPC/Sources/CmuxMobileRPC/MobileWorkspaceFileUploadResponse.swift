public import Foundation

/// A structurally validated upload acknowledgement, not proof of storage or host honesty.
///
/// The caller must also compare the request identity, bytes' digest and count. Neither root marker
/// nor digest grants authorization. The Mac path is opaque metadata, never an iOS filesystem URL.
///
/// ```swift
/// let receipt = try MobileWorkspaceFileUploadResponse.decode(resultData)
/// ```
public struct MobileWorkspaceFileUploadResponse: Decodable, Sendable, Equatable {
    /// Original valid UUID spelling.
    public let workspaceID: String
    /// Complete literal root-relative destination.
    public let path: String
    /// Lowercase root consistency marker, not a credential.
    public let rootID: String
    /// Integral complete byte count from zero through 2 MiB.
    public let byteCount: Int
    /// Lowercase digest claimed by the host, requiring comparison to the submitted bytes.
    public let sha256: String
    /// Opaque absolute Mac path with a byte-exact relative suffix; its prefix is host-declared.
    public let absolutePath: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", path, rootID = "root_id", byteCount = "byte_count", sha256
        case absolutePath = "absolute_path"
    }

    /// Requires six typed nonnull fields while permitting unknown future metadata.
    /// - Parameter decoder: Result-object decoder; this entry point cannot bound raw JSON length.
    /// - Throws: A decoding error for malformed or inconsistent fields.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        path = try values.decode(String.self, forKey: .path)
        rootID = try values.decode(String.self, forKey: .rootID)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        sha256 = try values.decode(String.self, forKey: .sha256)
        absolutePath = try values.decode(String.self, forKey: .absolutePath)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let leaf = components.last.map(String.init) ?? ""
        let suffix = ("/" + path).utf8
        guard UUID(uuidString: workspaceID) != nil, !path.isEmpty, path.utf8.count <= 4_096,
              !path.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              leaf.utf8.count <= 255, !leaf.contains("\\"),
              !leaf.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              Self.validHex(rootID), Self.validHex(sha256), (0...2_097_152).contains(byteCount),
              absolutePath.hasPrefix("/"), !absolutePath.contains("\0"), absolutePath.utf8.count <= 8_193,
              absolutePath.utf8.suffix(suffix.count).elementsEqual(suffix) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid file upload receipt"))
        }
    }

    /// Decodes a result within a fixed 128 KiB raw JSON budget, including unknown fields.
    /// - Parameter data: Result JSON, not a full RPC envelope.
    /// - Returns: A structurally validated acknowledgement.
    /// - Throws: A decoding error for an oversized result or invalid fields.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 131_072 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Oversized file upload receipt"))
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private static func validHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
