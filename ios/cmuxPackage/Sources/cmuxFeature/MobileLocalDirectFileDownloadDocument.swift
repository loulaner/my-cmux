import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Export-only, immutable complete bytes already verified by the download model.
struct MobileLocalDirectFileDownloadDocument: FileDocument, Sendable {
    enum Failure: Error { case tooLarge, unsupportedRead }
    let data: Data

    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.data] }

    init(data: Data) throws {
        guard data.count <= 2_097_152 else { throw Failure.tooLarge }
        self.data = data
    }

    init(configuration: ReadConfiguration) throws { throw Failure.unsupportedRead }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try makeFileWrapper() }

    /// Shared with the standalone fixture; never writes to a filesystem itself.
    func makeFileWrapper() throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
