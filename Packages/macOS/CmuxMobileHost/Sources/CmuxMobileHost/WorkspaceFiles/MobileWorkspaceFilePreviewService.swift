import Darwin
public import Foundation

/// Reads bounded raw bytes under a root already authorized by the caller.
///
/// The selected path resolves to its latest regular file, not a prior list's inode.
/// Root identity is checked before traversal. Same-fd metadata checks detect observable
/// changes, but do not lock the file or provide an OS-atomic snapshot or ancestry guarantee.
/// Root ancestors remain the caller's authorization boundary.
///
/// ```swift
/// let service = try MobileWorkspaceFilePreviewService(rootDirectory: authorizedWorkspaceURL)
/// let preview = try await service.read(relativePath: "README.md", expectedRootID: page.rootID)
/// ```
public actor MobileWorkspaceFilePreviewService {
    /// Maximum raw prefix length; callers cannot override it or request arbitrary offsets.
    public static let maximumPreviewBytes = 262_144
    private let directoryAccess: MobileWorkspaceDirectoryAccess

    /// Stores the caller-authorized root without filesystem I/O.
    /// - Parameter rootDirectory: Absolute local file URL whose ancestors the caller authorizes.
    /// - Throws: ``MobileWorkspaceFilePreviewError.invalidPath`` for invalid root syntax.
    public init(rootDirectory: URL) throws {
        do { directoryAccess = try MobileWorkspaceDirectoryAccess(rootDirectory: rootDirectory) }
        catch { throw MobileWorkspaceFilePreviewError.invalidPath }
    }

    /// Reads at most 256 KiB from a regular file without following relative symlinks.
    ///
    /// Cancellation is checked before opening, between reads/retries, and before returning;
    /// it cannot forcibly interrupt a single filesystem syscall. Bytes are not decoded.
    /// - Parameters:
    ///   - relativePath: Nonempty literal safe path, at most 4096 UTF-8 bytes.
    ///   - expectedRootID: Previously observed root marker; consistency only, not authorization.
    /// - Returns: The raw prefix, stable observed size and whether it is truncated.
    /// - Throws: A safe ``MobileWorkspaceFilePreviewError`` or unchanged ``CancellationError``.
    public func read(relativePath: String, expectedRootID: String) throws -> MobileWorkspaceFilePreview {
        do {
            let components = try MobileWorkspaceDirectoryAccess.components(relativePath: relativePath, allowRoot: false)
            guard let leaf = components.last else { throw MobileWorkspaceFilePreviewError.invalidPath }
            guard expectedRootID.utf8.count == 64,
                  expectedRootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw MobileWorkspaceFilePreviewError.invalidRequest
            }
            try Task.checkCancellation()
            let (parent, rootID) = try directoryAccess.openDirectory(components: Array(components.dropLast()), expectedRootID: expectedRootID)
            defer { close(parent) }
            let file = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw Self.failure(errno) }
            defer { close(file) }
            var before = stat()
            guard fstat(file, &before) == 0 else { throw Self.failure(errno) }
            guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw MobileWorkspaceFilePreviewError.notRegularFile }
            guard before.st_size >= 0 else { throw MobileWorkspaceFilePreviewError.unreadable }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while data.count < Self.maximumPreviewBytes {
                try Task.checkCancellation()
                let requested = min(buffer.count, Self.maximumPreviewBytes - data.count)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, requested) }
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw Self.failure(code)
                }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(file, &after) == 0 else { throw Self.failure(errno) }
            guard after.st_size >= 0 else { throw MobileWorkspaceFilePreviewError.unreadable }
            guard Self.stable(before, after), data.count == min(Int64(before.st_size), Int64(Self.maximumPreviewBytes)) else {
                throw MobileWorkspaceFilePreviewError.fileChanged
            }
            try Task.checkCancellation()
            return MobileWorkspaceFilePreview(relativePath: relativePath, rootID: rootID, data: data,
                totalBytes: Int64(before.st_size), truncated: Int64(before.st_size) > Int64(data.count))
        } catch {
            if error is CancellationError { throw error }
            if let failure = error as? MobileWorkspaceFilePreviewError { throw failure }
            if let failure = error as? MobileWorkspaceFileListError { throw Self.failure(failure) }
            throw MobileWorkspaceFilePreviewError.unreadable
        }
    }

    /// Same-descriptor checks are observable consistency, not atomic snapshot isolation.
    private static func stable(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec &&
            before.st_gen == after.st_gen
    }

    private static func failure(_ code: Int32) -> MobileWorkspaceFilePreviewError {
        failure(MobileWorkspaceDirectoryAccess.failure(code))
    }

    private static func failure(_ error: MobileWorkspaceFileListError) -> MobileWorkspaceFilePreviewError {
        switch error {
        case .invalidRequest: .invalidRequest
        case .invalidPath: .invalidPath
        case .notFound: .notFound
        case .notDirectory: .notRegularFile
        case .permissionDenied: .permissionDenied
        case .unreadable, .tooManyEntries: .unreadable
        }
    }
}
