import Darwin
public import Foundation

/// Lists one level beneath a root already authorized by the caller.
///
/// Each request anchors traversal to directory descriptors and never follows a
/// relative-component symlink. Root ancestors remain the caller's authorization
/// boundary: `O_NOFOLLOW` protects the root's final component, not its ancestors.
/// Directory mutation can change later pages; there is no cross-request snapshot.
///
/// ```swift
/// let service = try MobileWorkspaceFileListService(rootDirectory: authorizedWorkspaceURL)
/// let page = try await service.list(relativePath: "Sources", limit: 100)
/// ```
public actor MobileWorkspaceFileListService {
    private let rootPath: String
    private static let maximumEntries = 10_000
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK

    /// Stores an authorized root without performing filesystem I/O.
    /// - Parameter rootDirectory: An absolute file URL supplied by the trusted caller.
    /// - Throws: ``MobileWorkspaceFileListError.invalidPath`` for invalid root syntax.
    public init(rootDirectory: URL) throws {
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

    /// Enumerates and sorts one bounded directory before slicing a page.
    ///
    /// Cancellation is checked before opening, at each enumeration step, and
    /// before returning. It cannot forcibly interrupt a blocking OS directory call.
    /// - Parameters:
    ///   - relativePath: Defaults to empty for the root, otherwise unmodified relative components.
    ///   - offset: Nonnegative offset; defaults to zero to start at the first entry. Clamped to the count.
    ///   - limit: Page size from 1 through 100; defaults to the supported maximum of 100.
    /// - Returns: Metadata only, with no absolute paths or link target information.
    /// - Throws: A safe ``MobileWorkspaceFileListError``, or ``CancellationError`` unchanged.
    public func list(relativePath: String = "", offset: Int = 0, limit: Int = 100) throws -> MobileWorkspaceFileListPage {
        guard offset >= 0, (1...100).contains(limit) else { throw MobileWorkspaceFileListError.invalidRequest }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.contains("\0"), relativePath.utf8.count <= 4_096,
              relativePath.isEmpty || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MobileWorkspaceFileListError.invalidPath
        }
        try Task.checkCancellation()
        let descriptor = try openDirectory(components: relativePath.isEmpty ? [] : components.map(String.init))
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw Self.failure(code)
        }
        defer { closedir(directory) }
        var entries = try enumerate(directory, relativePath: relativePath)
        entries.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let start = min(offset, entries.count)
        let end = min(start + limit, entries.count)
        let parent = relativePath.isEmpty ? nil : components.dropLast().joined(separator: "/")
        try Task.checkCancellation()
        return MobileWorkspaceFileListPage(relativePath: relativePath, parentRelativePath: parent,
            entries: Array(entries[start..<end]), offset: start, limit: limit, totalCount: entries.count,
            nextOffset: end < entries.count ? end : nil)
    }

    /// Returns an owned descriptor, closing intermediate descriptors on every exit path.
    private func openDirectory(components: [String]) throws -> Int32 {
        var descriptor = open(rootPath, Self.directoryFlags)
        guard descriptor >= 0 else { throw Self.failure(errno) }
        defer { if descriptor >= 0 { close(descriptor) } }
        for component in components {
            try Task.checkCancellation()
            let child = openat(descriptor, component, Self.directoryFlags)
            guard child >= 0 else { throw Self.failure(errno) }
            close(descriptor)
            descriptor = child
        }
        let result = descriptor
        descriptor = -1 // Transfer to the caller, which hands it to fdopendir.
        return result
    }

    /// Counts non-dot entries before metadata filtering, including children that disappear.
    private func enumerate(_ directory: UnsafeMutablePointer<DIR>, relativePath: String) throws -> [MobileWorkspaceFileListEntry] {
        var entries: [MobileWorkspaceFileListEntry] = []
        var names = Set<[UInt8]>()
        var enumerated = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw Self.failure(errno) }
                break
            }
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }) else { throw MobileWorkspaceFileListError.unreadable }
            if name == "." || name == ".." { continue }
            enumerated += 1
            guard enumerated <= Self.maximumEntries else { throw MobileWorkspaceFileListError.tooManyEntries }
            guard names.insert(Array(name.utf8)).inserted else { throw MobileWorkspaceFileListError.unreadable }
            if let item = try metadata(directory: dirfd(directory), name: name, relativePath: relativePath) {
                entries.append(item)
            }
        }
        return entries
    }

    /// Reads only the entry itself; a disappearing child is omitted.
    private func metadata(directory: Int32, name: String, relativePath: String) throws -> MobileWorkspaceFileListEntry? {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw Self.failure(code)
        }
        let kind: MobileWorkspaceFileListEntry.Kind
        switch value.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        return MobileWorkspaceFileListEntry(
            name: name, relativePath: relativePath.isEmpty ? name : relativePath + "/" + name,
            kind: kind, byteCount: kind == .file ? max(0, Int64(value.st_size)) : nil
        )
    }

    private static func failure(_ code: Int32) -> MobileWorkspaceFileListError {
        switch code {
        case ENOENT: .notFound
        case ENOTDIR, ELOOP: .notDirectory
        case EACCES, EPERM: .permissionDenied
        case ENAMETOOLONG: .invalidPath
        default: .unreadable
        }
    }
}
