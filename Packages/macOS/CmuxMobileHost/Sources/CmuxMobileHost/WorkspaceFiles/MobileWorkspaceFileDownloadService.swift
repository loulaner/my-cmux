import CryptoKit
public import Foundation

/// Reads complete raw files up to 2 MiB beneath a caller-authorized workspace root.
///
/// Resolves the latest regular file at the path, not a prior list's inode/version.
/// The caller owns workspace authorization, provenance, policy and root-ancestor trust.
/// Descriptor metadata checks detect observable changes, not an OS-atomic snapshot.
/// No output file is created, content interpreted or connection owned by this service.
///
/// ```swift
/// let service = try MobileWorkspaceFileDownloadService(rootDirectory: authorizedRoot)
/// let file = try await service.read(relativePath: "archive.bin", expectedRootID: page.rootID)
/// ```
public actor MobileWorkspaceFileDownloadService {
    /// Fixed maximum complete-file size, 2 MiB; callers cannot request ranges or override it.
    public static let maximumDownloadBytes = MobileWorkspaceFileByteReader.maximumDownloadBytes
    private let reader: MobileWorkspaceFileByteReader

    /// Stores a validated root without filesystem I/O.
    /// - Parameter rootDirectory: Absolute local file URL; its ancestors must be authorized by the caller.
    /// - Throws: ``MobileWorkspaceFileDownloadError/invalidPath`` for invalid root syntax.
    public init(rootDirectory: URL) throws {
        do { reader = try MobileWorkspaceFileByteReader(rootDirectory: rootDirectory) }
        catch { throw MobileWorkspaceFileDownloadError.invalidPath }
    }

    /// Reads an entire regular file without following relative symlinks, then hashes returned bytes.
    ///
    /// Oversized regular files are refused before allocating read buffers or reading bytes.
    /// Cancellation is checked between reads and before/after hashing; a single syscall or hash
    /// cannot be forcibly interrupted. No partial success is returned.
    /// - Parameters:
    ///   - relativePath: Nonempty literal safe relative path, at most 4096 UTF-8 bytes.
    ///   - expectedRootID: Observed consistency marker, not authorization.
    /// - Returns: Complete bytes with their SHA-256 integrity digest.
    /// - Throws: A safe ``MobileWorkspaceFileDownloadError`` or unchanged ``CancellationError``.
    public func read(relativePath: String, expectedRootID: String) throws -> MobileWorkspaceFileDownload {
        do {
            let result = try reader.read(relativePath: relativePath, expectedRootID: expectedRootID, mode: .download)
            guard !result.truncated, Int64(result.data.count) == result.totalBytes else {
                throw MobileWorkspaceFileDownloadError.fileChanged
            }
            try Task.checkCancellation()
            let digest = SHA256.hash(data: result.data).map { String(format: "%02x", $0) }.joined()
            try Task.checkCancellation()
            return MobileWorkspaceFileDownload(relativePath: result.relativePath, rootID: result.rootID,
                data: result.data, sha256: digest)
        } catch {
            if error is CancellationError { throw error }
            if let failure = error as? MobileWorkspaceFileDownloadError { throw failure }
            if error is MobileWorkspaceFileByteReader.Failure { throw MobileWorkspaceFileDownloadError.tooLarge }
            if let failure = error as? MobileWorkspaceFilePreviewError { throw Self.failure(failure) }
            throw MobileWorkspaceFileDownloadError.unreadable
        }
    }

    private static func failure(_ error: MobileWorkspaceFilePreviewError) -> MobileWorkspaceFileDownloadError {
        switch error {
        case .invalidRequest: .invalidRequest
        case .invalidPath: .invalidPath
        case .rootChanged: .rootChanged
        case .notFound: .notFound
        case .notRegularFile: .notRegularFile
        case .permissionDenied: .permissionDenied
        case .fileChanged: .fileChanged
        case .unreadable: .unreadable
        }
    }
}
