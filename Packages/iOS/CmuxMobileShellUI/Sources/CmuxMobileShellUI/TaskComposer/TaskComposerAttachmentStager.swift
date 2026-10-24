#if os(iOS)
import CmuxMobileShellModel
import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file-backed transfer for any asset returned by the Photos picker.
///
/// PhotosUI owns the URL in `ReceivedTransferredFile`, so copy it into an
/// app-owned temporary file before the picker transfer goes out of scope. The
/// concrete representations let PhotosUI choose its native file form for
/// common images and movies before falling back to the generic `.item` form for
/// Live Photos and future library media.
struct ImportedPhotoLibraryFile: Transferable, Sendable {
    enum Kind: Equatable, Sendable {
        case image
        case file
    }

    let url: URL
    let originalFileName: String
    let kind: Kind

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .livePhoto) { received in
            try importFile(received, kind: .file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try importFile(received, kind: .image)
        }
        FileRepresentation(importedContentType: .video) { received in
            try importFile(received, kind: .file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try importFile(received, kind: .file)
        }
        FileRepresentation(importedContentType: .item) { received in
            try importFile(received, kind: .file)
        }
    }

    private static func importFile(
        _ received: ReceivedTransferredFile,
        kind: Kind
    ) throws -> Self {
        let ext = received.file.pathExtension
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-task-photo-import-" + name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: received.file, to: destination)
        return Self(
            url: destination,
            originalFileName: received.file.lastPathComponent,
            kind: kind
        )
    }
}

enum PhotoLibraryTransferError: Error {
    case timedOut
}

private final class PhotoLibraryTransferRace: @unchecked Sendable {
    // `start` must store the continuation inside the synchronous
    // `withCheckedThrowingContinuation` closure, and `cancel` runs in the
    // synchronous `onCancel:` of `withTaskCancellationHandler`. Neither can
    // await, so an actor would force both through a detached Task and lose the
    // ordering that keeps a resume from racing the store. Carve-out: the race
    // is settled by `didFinish` under this lock, which resumes exactly once.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ImportedPhotoLibraryFile?, Error>?
    private var transferTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    func start(
        item: PhotosPickerItem,
        timeout: Duration,
        continuation: CheckedContinuation<ImportedPhotoLibraryFile?, Error>
    ) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let transferTask = Task { [self] in
            do {
                try Task.checkCancellation()
                let imported = try await item.loadTransferable(
                    type: ImportedPhotoLibraryFile.self
                )
                finish(.success(imported))
            } catch {
                finish(.failure(error))
            }
        }
        let timeoutTask = Task { [self] in
            do {
                try await Task.sleep(for: timeout)
                finish(.failure(PhotoLibraryTransferError.timedOut))
            } catch {
                // The transfer won or the parent task was cancelled.
            }
        }

        lock.lock()
        if didFinish {
            lock.unlock()
            transferTask.cancel()
            timeoutTask.cancel()
        } else {
            self.transferTask = transferTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(
        _ result: Result<ImportedPhotoLibraryFile?, Error>
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        let transferTask = self.transferTask
        self.transferTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        transferTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

extension ImportedPhotoLibraryFile {
    /// Loads a Photos library asset with a bounded wait. iCloud-backed assets can
    /// otherwise leave a composer staging task waiting indefinitely when the
    /// network transfer stalls.
    static func load(
        _ item: PhotosPickerItem,
        timeout: Duration = .seconds(60)
    ) async throws -> ImportedPhotoLibraryFile? {
        let race = PhotoLibraryTransferRace()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    item: item,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        }, onCancel: {
            race.cancel()
        })
    }
}
#endif
