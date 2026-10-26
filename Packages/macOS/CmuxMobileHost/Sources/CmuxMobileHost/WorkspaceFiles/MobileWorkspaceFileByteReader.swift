import Darwin
import Foundation

/// The sole no-follow leaf reader; callers invoke synchronously on their service actor.
/// Root ancestors and workspace authorization remain the caller's responsibility.
struct MobileWorkspaceFileByteReader: Sendable {
    enum Mode: Sendable { case preview, download }
    enum Failure: Error, Sendable { case tooLarge }
    static let maximumPreviewBytes = 262_144
    static let maximumDownloadBytes = 2_097_152
    private let directoryAccess: MobileWorkspaceDirectoryAccess

    /// Validates root syntax without filesystem I/O, preserving preview's safe error contract.
    init(rootDirectory: URL) throws {
        do { directoryAccess = try MobileWorkspaceDirectoryAccess(rootDirectory: rootDirectory) }
        catch { throw MobileWorkspaceFilePreviewError.invalidPath }
    }

    /// Reads a bounded prefix or an entire size-limited file; neither is an atomic snapshot.
    func read(relativePath: String, expectedRootID: String, mode: Mode) throws -> (relativePath: String, rootID: String, data: Data, totalBytes: Int64, truncated: Bool) {
        let limit = mode == .preview ? Self.maximumPreviewBytes : Self.maximumDownloadBytes
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
            if mode == .download, before.st_size > Int64(Self.maximumDownloadBytes) { throw Failure.tooLarge }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while data.count < limit {
                try Task.checkCancellation()
                let requested = min(buffer.count, limit - data.count)
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
            guard Self.stable(before, after), data.count == min(Int64(before.st_size), Int64(limit)) else {
                throw MobileWorkspaceFilePreviewError.fileChanged
            }
            try Task.checkCancellation()
            return (relativePath: relativePath, rootID: rootID, data: data,
                totalBytes: Int64(before.st_size), truncated: Int64(before.st_size) > Int64(data.count))
        } catch {
            if error is CancellationError { throw error }
            if let failure = error as? Failure { throw failure }
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
