import Darwin
public import Foundation

/// Bounded, coordinated reads of a file explicitly selected by the user.
///
/// The caller/system supplies access authority; a URL alone does not grant permission.
/// Provider coordination cannot be forcibly interrupted or bound its internal download volume.
///
/// ```swift
/// let reader = MobileLocalDirectFileImportReader()
/// let selection = try await reader.read(selectedURL)
/// ```
public actor MobileLocalDirectFileImportReader {
    /// Maximum complete file size accepted before allocating a content buffer.
    public static let maximumByteCount = 2_097_152

    /// An original source name and complete bytes, with no source URL retained.
    public struct Selection: Sendable {
        /// Original selected leaf, not a provider's temporary coordinated name.
        public let fileName: String
        /// Complete source bytes, at most ``MobileLocalDirectFileImportReader/maximumByteCount``.
        public let data: Data
    }

    /// Safe failures without provider messages or source paths.
    public enum Failure: Error, Equatable, Sendable {
        /// The source leaf is not a safe upload filename.
        case invalidName
        /// The selected item is not a regular file or is a symbolic link.
        case notAFile
        /// The complete file exceeds the input budget.
        case tooLarge
        /// Access was denied by the provider or filesystem.
        case permissionDenied
        /// File metadata or length changed during the read.
        case fileChanged
        /// The URL, provider, or file could not be read.
        case unavailable
    }

    /// Creates an independent reader without accessing files or providers.
    public init() {}

    /// Coordinates and reads a caller-selected file without staging or changing it.
    /// - Parameter url: File URL selected through an authorized system/caller flow.
    /// - Returns: Original filename and complete bounded bytes.
    /// - Throws: ``Failure`` or `CancellationError`; never a raw provider error.
    public func read(_ url: URL) throws -> Selection {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.contains("\0") else { throw Failure.unavailable }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidName
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var original = stat()
        let visible = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &original) == 0
        }
        if visible, original.st_mode & S_IFMT != S_IFREG { throw Failure.notAFile }
        try Task.checkCancellation()
        var coordinationError: NSError?
        var result: Result<Data, any Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Self.readCoordinated(coordinatedURL) }
        }
        try Task.checkCancellation()
        if let coordinationError {
            if coordinationError.domain == NSCocoaErrorDomain, coordinationError.code == NSUserCancelledError {
                throw CancellationError()
            }
            throw Self.safeFailure(coordinationError)
        }
        guard let result else { throw Failure.unavailable }
        do { return Selection(fileName: name, data: try result.get()) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch { throw Failure.unavailable }
    }

    private static func readCoordinated(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.contains("\0") else { throw Failure.unavailable }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw posixFailure(errno) }
        defer { Darwin.close(fd) }
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0 else { throw posixFailure(errno) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw Failure.notAFile }
        guard before.st_size >= 0 else { throw Failure.unavailable }
        guard before.st_size <= Self.maximumByteCount else { throw Failure.tooLarge }
        let count = Int(before.st_size)
        var bytes = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65_536))
        var interruptions = 0
        while bytes.count < count {
            try Task.checkCancellation()
            let wanted = min(buffer.count, count - bytes.count)
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if amount < 0 {
                let code = errno
                if code == EINTR, interruptions < 3 { interruptions += 1; continue }
                throw posixFailure(code)
            }
            guard amount > 0 else { throw Failure.fileChanged }
            interruptions = 0
            bytes.append(contentsOf: buffer.prefix(amount))
        }
        try Task.checkCancellation()
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0 else { throw posixFailure(errno) }
        guard bytes.count == count, sameFile(before, after) else { throw Failure.fileChanged }
        return bytes
    }

    private static func sameFile(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_mode == after.st_mode &&
        before.st_nlink == after.st_nlink && before.st_uid == after.st_uid && before.st_gid == after.st_gid && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec &&
        before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec && before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec &&
        before.st_gen == after.st_gen && before.st_flags == after.st_flags
    }

    private static func posixFailure(_ code: Int32) -> Failure {
        switch code {
        case EACCES, EPERM: .permissionDenied
        case ELOOP, EISDIR: .notAFile
        default: .unavailable
        }
    }

    private static func safeFailure(_ error: NSError) -> Failure {
        if error.domain == NSPOSIXErrorDomain { return posixFailure(Int32(clamping: error.code)) }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return .permissionDenied }
        return .unavailable
    }
}
