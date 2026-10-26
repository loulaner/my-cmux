import CryptoKit
import Darwin
import Foundation

/// Owns shared no-follow traversal beneath a caller-authorized root, not authorization itself.
struct MobileWorkspaceDirectoryAccess: Sendable {
    private let rootPath: String
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK

    init(rootDirectory: URL) throws {
        let path = rootDirectory.path(percentEncoded: false)
        guard rootDirectory.isFileURL, path.hasPrefix("/"), !path.contains("\0"),
              !path.isEmpty, path.utf8.count <= 4_096 else {
            throw MobileWorkspaceFileListError.invalidPath
        }
        // A trailing slash must not turn the final component into an ancestor
        // and bypass O_NOFOLLOW (including URLs explicitly marked as directories).
        var openedPath = path
        while openedPath.count > 1 && openedPath.hasSuffix("/") { openedPath.removeLast() }
        rootPath = openedPath
    }

    /// Validates literal components, without expanding or decoding request paths.
    static func components(relativePath: String, allowRoot: Bool) throws -> [String] {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.contains("\0"), relativePath.utf8.count <= 4_096,
              (allowRoot && relativePath.isEmpty) || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MobileWorkspaceFileListError.invalidPath
        }
        return relativePath.isEmpty ? [] : components.map(String.init)
    }

    /// Transfers one owned fd; intermediate/error descriptors are closed exactly once.
    /// Root ancestors remain the caller's boundary. Renames do not change the opened object.
    func openDirectory(components: [String], expectedRootID: String? = nil) throws -> (descriptor: Int32, rootID: String) {
        var descriptor = open(rootPath, Self.directoryFlags)
        guard descriptor >= 0 else { throw Self.failure(errno) }
        defer { if descriptor >= 0 { close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw Self.failure(errno) }
        let rootID = rootID(metadata)
        if let expectedRootID, expectedRootID != rootID { throw MobileWorkspaceFilePreviewError.rootChanged }
        for component in components {
            try Task.checkCancellation()
            let child = openat(descriptor, component, Self.directoryFlags)
            guard child >= 0 else { throw Self.failure(errno) }
            close(descriptor)
            descriptor = child
        }
        let result = descriptor
        descriptor = -1 // Transfer to the caller, which owns close/fdopendir.
        return (result, rootID)
    }

    /// Versioned consistency marker, excluding mutable child-related mtime/ctime.
    /// Birth/generation reduce inode reuse ambiguity, not a strong filesystem ABA guarantee.
    private func rootID(_ value: stat) -> String {
        let input = "v1\0" + rootPath + "\0" + String(value.st_dev) + "\0" + String(value.st_ino) + "\0"
            + String(value.st_birthtimespec.tv_sec) + "\0" + String(value.st_birthtimespec.tv_nsec) + "\0" + String(value.st_gen)
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func failure(_ code: Int32) -> MobileWorkspaceFileListError {
        switch code {
        case ENOENT: .notFound
        case ENOTDIR, ELOOP: .notDirectory
        case EACCES, EPERM: .permissionDenied
        case ENAMETOOLONG: .invalidPath
        default: .unreadable
        }
    }
}
