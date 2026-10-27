public import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A provider-supplied image file read before its transfer callback returns.
/// Only this app's read is bounded; provider downloads, conversion and temporary materialization are not.
/// The supplied filename is retained and the bytes are not decoded, resized or format-validated.
public struct MobileLocalDirectPhotoTransfer: Transferable, Sendable {
    /// Complete bounded bytes and provider-supplied filename, with no retained temporary URL.
    public let selection: MobileLocalDirectFileImportReader.Selection

    /// Import-only file transfer; the temporary source is consumed within the asynchronous callback.
    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try await importFile(received.file)
        }
    }

    static func importFile(_ url: URL) async throws -> Self {
        let reader = MobileLocalDirectFileImportReader()
        return Self(selection: try await reader.read(url))
    }
}
