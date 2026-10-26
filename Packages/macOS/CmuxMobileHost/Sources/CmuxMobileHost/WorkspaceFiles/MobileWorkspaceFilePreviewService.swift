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
    public static let maximumPreviewBytes = MobileWorkspaceFileByteReader.maximumPreviewBytes
    private let reader: MobileWorkspaceFileByteReader

    /// Stores the caller-authorized root without filesystem I/O.
    /// - Parameter rootDirectory: Absolute local file URL whose ancestors the caller authorizes.
    /// - Throws: ``MobileWorkspaceFilePreviewError.invalidPath`` for invalid root syntax.
    public init(rootDirectory: URL) throws {
        do { reader = try MobileWorkspaceFileByteReader(rootDirectory: rootDirectory) }
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
            let result = try reader.read(relativePath: relativePath, expectedRootID: expectedRootID, mode: .preview)
            return MobileWorkspaceFilePreview(relativePath: result.relativePath, rootID: result.rootID,
                data: result.data, totalBytes: result.totalBytes, truncated: result.truncated)
        } catch is MobileWorkspaceFileByteReader.Failure {
            // The whole-file-only size refusal is unreachable in preview mode.
            throw MobileWorkspaceFilePreviewError.unreadable
        }
    }
}
