import CmuxMobileRPC
import Foundation

/// Performs bounded JSON/base64/hash work on its own actor, not the UI actor.
actor MobileWorkspaceFileDownloadDecoder {
    /// A single hash cannot be interrupted; cancellation is checked before and after decoding.
    func decode(_ data: Data) throws -> MobileWorkspaceFileDownloadResponse {
        try Task.checkCancellation()
        let response = try MobileWorkspaceFileDownloadResponse.decode(data)
        try Task.checkCancellation()
        return response
    }
}
