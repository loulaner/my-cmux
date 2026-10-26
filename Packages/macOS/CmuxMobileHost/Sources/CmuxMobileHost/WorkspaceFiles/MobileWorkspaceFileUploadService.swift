import CryptoKit
import Darwin
public import Foundation

/// Publishes complete new files beneath a caller-authorized root, never replacing a destination.
///
/// The caller owns authorization, root-ancestor trust and the mandatory latest-admission gate.
/// No-follow descriptors and metadata checks detect observable namespace changes, not atomic
/// authorization or isolation from malicious same-UID processes. Open directories can be moved.
/// Publication is exclusive but not crash-durable; a committed file is never removed on response failure.
///
/// ```swift
/// let service = try MobileWorkspaceFileUploadService(rootDirectory: authorizedRoot)
/// let result = try await service.write(relativeDirectoryPath: "", fileName: "note.txt",
///     data: bytes, expectedRootID: rootID, expectedSHA256: digest, beforeCommit: recheckAdmission)
/// ```
public actor MobileWorkspaceFileUploadService {
    /// Fixed complete-payload limit; no configurable budget, ranges or resume semantics.
    public static let maximumUploadBytes = 2_097_152
    private let access: MobileWorkspaceDirectoryAccess
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Validates and stores a root without filesystem I/O.
    /// - Parameter rootDirectory: Absolute local file URL with caller-authorized ancestors.
    /// - Throws: ``MobileWorkspaceFileUploadError/invalidPath`` for invalid root syntax.
    public init(rootDirectory: URL) throws {
        do { access = try MobileWorkspaceDirectoryAccess(rootDirectory: rootDirectory) }
        catch { throw MobileWorkspaceFileUploadError.invalidPath }
    }

    /// Stages full verified bytes, awaits the caller's latest admission check, then publishes exclusively.
    /// - Parameters:
    ///   - relativeDirectoryPath: Literal existing root-relative directory; empty means the root.
    ///   - fileName: Unmodified safe leaf, at most 255 UTF-8 bytes.
    ///   - data: Complete bytes, including a valid empty payload, at most 2 MiB.
    ///   - expectedRootID: Required lowercase 64-byte hexadecimal root consistency marker.
    ///   - expectedSHA256: Required lowercase SHA-256, checked before any filesystem I/O.
    ///   - beforeCommit: Mandatory caller-owned authorization/policy/workspace recheck; no default.
    /// - Returns: A complete published file; cancellation is not checked after successful publication.
    /// - Throws: Safe ``MobileWorkspaceFileUploadError``, unchanged cancellation, or the gate's original error.
    public func write(relativeDirectoryPath: String, fileName: String, data: Data,
                      expectedRootID: String, expectedSHA256: String,
                      beforeCommit: @Sendable () async throws -> Void) async throws -> MobileWorkspaceFileUpload {
        try Task.checkCancellation()
        let components: [String]
        do { components = try MobileWorkspaceDirectoryAccess.components(relativePath: relativeDirectoryPath, allowRoot: true) }
        catch { throw Self.failure(error) }
        guard !fileName.isEmpty, fileName != ".", fileName != "..", fileName.utf8.count <= 255,
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MobileWorkspaceFileUploadError.invalidPath
        }
        let relativePath = relativeDirectoryPath.isEmpty ? fileName : relativeDirectoryPath + "/" + fileName
        guard relativePath.utf8.count <= 4_096 else { throw MobileWorkspaceFileUploadError.invalidPath }
        guard Self.validHex(expectedRootID), Self.validHex(expectedSHA256) else { throw MobileWorkspaceFileUploadError.invalidRequest }
        guard data.count <= Self.maximumUploadBytes else { throw MobileWorkspaceFileUploadError.tooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw MobileWorkspaceFileUploadError.integrityMismatch }
        try Task.checkCancellation()

        let directory = try openDirectory(components, expectedRootID)
        let target = directory.descriptor
        defer { close(target) }
        let targetMetadata = try Self.metadata(target)
        var stageName = ""
        var stageMetadata: stat?
        var stage: Int32 = -1
        var content: Int32 = -1
        var contentMetadata: stat?
        var published = false
        defer {
            Self.cleanup(target: target, name: stageName, stage: stage, stageMetadata: stageMetadata,
                         contentMetadata: contentMetadata, published: published)
            if content >= 0 { close(content) }
            if stage >= 0 { close(stage) }
        }
        for _ in 0..<3 {
            try Task.checkCancellation()
            let candidate = ".my-cmux-upload-" + UUID().uuidString
            if mkdirat(target, candidate, 0o700) == 0 { stageName = candidate; break }
            if errno != EEXIST { throw Self.failure(errno) }
        }
        guard !stageName.isEmpty else { throw MobileWorkspaceFileUploadError.unwritable }
        stageMetadata = try Self.metadata(at: target, name: stageName)
        guard let stageMetadata, Self.isDirectory(stageMetadata), stageMetadata.st_mode & 0o077 == 0 else {
            throw MobileWorkspaceFileUploadError.fileChanged
        }
        stage = openat(target, stageName, Self.directoryFlags)
        guard stage >= 0 else { throw Self.failure(errno) }
        guard Self.sameIdentity(stageMetadata, try Self.metadata(stage)) else { throw MobileWorkspaceFileUploadError.fileChanged }
        content = openat(stage, "content", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard content >= 0 else { throw Self.failure(errno) }
        contentMetadata = try Self.metadata(content)
        guard let contentMetadata, Self.isRegular(contentMetadata), contentMetadata.st_nlink == 1,
              contentMetadata.st_size == 0, contentMetadata.st_mode & 0o077 == 0 else { throw MobileWorkspaceFileUploadError.fileChanged }
        try Self.writeBytes(data, descriptor: content)
        let before = try Self.metadata(content)
        guard Self.sameIdentity(contentMetadata, before), Self.isRegular(before), before.st_nlink == 1,
              before.st_size == off_t(data.count), before.st_mode == contentMetadata.st_mode else { throw MobileWorkspaceFileUploadError.fileChanged }
        try Task.checkCancellation()
        // Gate errors must never pass through the OS-error mapper or cleanup error handling.
        try await beforeCommit()
        try Task.checkCancellation()
        let reopened = try openDirectory(components, expectedRootID)
        defer { close(reopened.descriptor) }
        guard Self.sameIdentity(targetMetadata, try Self.metadata(reopened.descriptor)) else { throw MobileWorkspaceFileUploadError.fileChanged }
        let stageNow = try Self.changedMetadata(at: target, name: stageName)
        guard Self.isDirectory(stageNow), Self.sameIdentity(stageMetadata, stageNow),
              stageNow.st_mode == stageMetadata.st_mode, Self.sameIdentity(stageMetadata, try Self.metadata(stage)) else {
            throw MobileWorkspaceFileUploadError.fileChanged
        }
        let leafNow = try Self.changedMetadata(at: stage, name: "content")
        let after = try Self.metadata(content)
        guard Self.isRegular(leafNow), Self.sameIdentity(before, leafNow), Self.unchanged(before, after),
              Self.unchanged(after, leafNow) else { throw MobileWorkspaceFileUploadError.fileChanged }
        try Task.checkCancellation()
        guard renameatx_np(stage, "content", target, fileName, UInt32(RENAME_EXCL)) == 0 else { throw Self.failure(errno) }
        published = true
        return MobileWorkspaceFileUpload(relativePath: relativePath, rootID: directory.rootID, byteCount: data.count, sha256: digest)
    }

    private func openDirectory(_ components: [String], _ marker: String) throws -> (descriptor: Int32, rootID: String) {
        do { return try access.openDirectory(components: components, expectedRootID: marker) }
        catch { throw Self.failure(error) }
    }

    private static func validHex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func writeBytes(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            var interruptions = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 {
                    if errno == EINTR, interruptions < 3 { interruptions += 1; continue }
                    throw failure(errno)
                }
                guard count > 0 else { throw MobileWorkspaceFileUploadError.unwritable }
                interruptions = 0
                offset += count
            }
            guard offset == data.count else { throw MobileWorkspaceFileUploadError.unwritable }
        }
    }

    private static func metadata(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failure(errno) }
        return value
    }

    private static func metadata(at descriptor: Int32, name: String) throws -> stat {
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(errno) }
        return value
    }

    private static func changedMetadata(at descriptor: Int32, name: String) throws -> stat {
        do { return try metadata(at: descriptor, name: name) }
        catch { throw MobileWorkspaceFileUploadError.fileChanged }
    }

    private static func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    private static func isRegular(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG }
    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_gen == rhs.st_gen
            && lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec && lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec
    }
    private static func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink && rhs.st_nlink == 1
            && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_flags == rhs.st_flags && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    /// Best-effort, identity-checked cleanup only; ambiguous/replaced paths are left behind.
    /// No recursive removal, final-name deletion or cleanup error replacing a committed result.
    private static func cleanup(target: Int32, name: String, stage: Int32, stageMetadata: stat?, contentMetadata: stat?, published: Bool) {
        guard let stageMetadata, let current = try? metadata(at: target, name: name),
              isDirectory(current), sameIdentity(stageMetadata, current) else { return }
        if stage >= 0, let opened = try? metadata(stage), sameIdentity(stageMetadata, opened) {
            if !published, let contentMetadata, let leaf = try? metadata(at: stage, name: "content"),
               isRegular(leaf), sameIdentity(contentMetadata, leaf) { _ = unlinkat(stage, "content", 0) }
        }
        // Rmdir cannot remove a replacement symlink or a directory with unrecognized contents.
        guard let final = try? metadata(at: target, name: name), isDirectory(final), sameIdentity(stageMetadata, final) else { return }
        _ = unlinkat(target, name, AT_REMOVEDIR)
    }

    private static func failure(_ code: Int32) -> MobileWorkspaceFileUploadError {
        switch code {
        case EEXIST, ENOTEMPTY: .alreadyExists
        case ENOENT: .notFound
        case ENOTDIR, ELOOP: .notDirectory
        case EACCES, EPERM: .permissionDenied
        case ENAMETOOLONG: .invalidPath
        default: .unwritable
        }
    }

    private static func failure(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? MobileWorkspaceFileListError {
            switch error {
            case .invalidRequest: return MobileWorkspaceFileUploadError.invalidRequest
            case .invalidPath: return MobileWorkspaceFileUploadError.invalidPath
            case .notFound: return MobileWorkspaceFileUploadError.notFound
            case .notDirectory: return MobileWorkspaceFileUploadError.notDirectory
            case .permissionDenied: return MobileWorkspaceFileUploadError.permissionDenied
            case .unreadable, .tooManyEntries: return MobileWorkspaceFileUploadError.unwritable
            }
        }
        if let error = error as? MobileWorkspaceFilePreviewError {
            switch error {
            case .rootChanged: return MobileWorkspaceFileUploadError.rootChanged
            case .invalidRequest: return MobileWorkspaceFileUploadError.invalidRequest
            case .invalidPath: return MobileWorkspaceFileUploadError.invalidPath
            case .notFound: return MobileWorkspaceFileUploadError.notFound
            case .notRegularFile: return MobileWorkspaceFileUploadError.notDirectory
            case .permissionDenied: return MobileWorkspaceFileUploadError.permissionDenied
            case .fileChanged: return MobileWorkspaceFileUploadError.fileChanged
            case .unreadable: return MobileWorkspaceFileUploadError.unwritable
            }
        }
        return MobileWorkspaceFileUploadError.unwritable
    }
}
