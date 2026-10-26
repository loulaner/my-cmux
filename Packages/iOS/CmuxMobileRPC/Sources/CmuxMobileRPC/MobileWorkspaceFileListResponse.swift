public import Foundation

/// A strictly validated metadata page, not a stable cross-request directory snapshot.
///
/// ```swift
/// let page = try MobileWorkspaceFileListResponse.decode(responseData)
/// ```
public struct MobileWorkspaceFileListResponse: Decodable, Sendable, Equatable {
    /// One immediate child, with no absolute path or link target.
    public struct Entry: Decodable, Sendable, Equatable {
        /// The entry's own kind; unknown kinds fail decoding rather than granting navigation.
        public enum Kind: String, Decodable, Sendable, Equatable {
            /// A regular file; metadata only, not a content-read grant.
            case file
            /// A directory eligible for explicit navigation.
            case directory
            /// A link that must never be traversed.
            case symbolicLink
            /// Any other filesystem object.
            case other
        }
        /// Original single-component name, at most 4096 UTF-8 bytes.
        public let name: String
        /// Original root-relative child path, potentially longer than a navigation request permits.
        public let path: String
        /// The entry's own kind, without following links.
        public let kind: Kind
        /// Nonnegative regular-file size; exactly null for all other kinds.
        public let size: Int64?

        private enum CodingKeys: String, CodingKey { case name, path, kind, size }

        /// Decodes an entry without dropping malformed fields or inventing defaults.
        /// - Parameter decoder: Decoder for one entry.
        /// - Throws: A decoding error for missing keys, invalid types or invalid metadata.
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            path = try values.decode(String.self, forKey: .path)
            kind = try values.decode(Kind.self, forKey: .kind)
            guard values.contains(.size) else { throw Self.invalid(decoder) }
            size = try values.decodeIfPresent(Int64.self, forKey: .size)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
                  name.utf8.count <= 4_096 else { throw Self.invalid(decoder) }
            if kind == .file {
                guard let size, size >= 0 else { throw Self.invalid(decoder) }
            } else if size != nil { throw Self.invalid(decoder) }
        }

        private static func invalid(_ decoder: any Decoder) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid file metadata"))
        }
    }

    /// UUID identifying the workspace represented by this page.
    public let workspaceID: String
    /// Safe root-relative directory; empty means the root.
    public let path: String
    /// Exact relative parent; null at the root.
    public let parentPath: String?
    /// Strict UTF-8 byte-ordered entries with no String-identity collisions.
    public let entries: [Entry]
    /// Clamped offset from this enumeration.
    public let offset: Int
    /// Accepted page size, from 1 through 100.
    public let limit: Int
    /// Enumeration size, at most 10,000.
    public let totalCount: Int
    /// Exact next offset if entries remain; otherwise null.
    public let nextOffset: Int?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", path, parentPath = "parent_path", entries, offset, limit
        case totalCount = "total_count", nextOffset = "next_offset"
    }

    /// Decodes a complete page and checks its ordering, parent and pagination invariants.
    /// - Parameter decoder: Decoder for the RPC result object.
    /// - Throws: A decoding error for any invalid entry or inconsistent page.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        path = try values.decode(String.self, forKey: .path)
        guard values.contains(.parentPath), values.contains(.nextOffset) else { throw Self.invalid(decoder) }
        parentPath = try values.decodeIfPresent(String.self, forKey: .parentPath)
        entries = try values.decode([Entry].self, forKey: .entries)
        offset = try values.decode(Int.self, forKey: .offset)
        limit = try values.decode(Int.self, forKey: .limit)
        totalCount = try values.decode(Int.self, forKey: .totalCount)
        nextOffset = try values.decodeIfPresent(Int.self, forKey: .nextOffset)
        guard UUID(uuidString: workspaceID) != nil, Self.validPath(path),
              offset >= 0, totalCount >= offset, totalCount <= 10_000, (1...100).contains(limit),
              entries.count == min(limit, totalCount - offset) else { throw Self.invalid(decoder) }
        let end = offset + entries.count
        guard nextOffset == (end < totalCount ? end : nil) else { throw Self.invalid(decoder) }
        if path.isEmpty {
            guard parentPath == nil else { throw Self.invalid(decoder) }
        } else {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            guard let parentPath, parentPath.utf8.elementsEqual(parent.utf8) else { throw Self.invalid(decoder) }
        }
        var previous: String?
        var identities = Set<String>()
        for entry in entries {
            let expected = path.isEmpty ? entry.name : path + "/" + entry.name
            guard entry.path.utf8.elementsEqual(expected.utf8), identities.insert(entry.path).inserted else {
                throw Self.invalid(decoder)
            }
            if let previous, !previous.utf8.lexicographicallyPrecedes(entry.name.utf8) { throw Self.invalid(decoder) }
            previous = entry.name
        }
    }

    /// Decodes a strict page from RPC result bytes.
    /// - Parameter data: JSON response bytes, without an RPC envelope.
    /// - Returns: A validated page with all entries intact.
    /// - Throws: A decoding error; malformed entries are never silently omitted.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private static func validPath(_ path: String) -> Bool {
        path.utf8.count <= 4_096 && !path.contains("\0") && (path.isEmpty ||
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
    }

    private static func invalid(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid workspace file page"))
    }
}
