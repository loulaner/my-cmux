public import Foundation

/// Scoped persistence for local direct-device records, independent of cloud credentials.
public protocol CmxLocalDeviceCredentialStorage: Sendable {
    /// Reads one opaque scoped record; nil means no record exists.
    /// - Parameter account: The store-derived namespace and encoded scope.
    /// - Returns: Stored data or nil.
    /// - Throws: A storage failure; callers must not expose raw error contents.
    func read(account: String) async throws -> Data?
    /// Atomically replaces one scoped record.
    /// - Parameters:
    ///   - data: The versioned device digest list, never bearer tokens.
    ///   - account: The store-derived namespace and encoded scope.
    /// - Throws: A storage failure; success is required before publishing changes.
    func write(_ data: Data, account: String) async throws
}
