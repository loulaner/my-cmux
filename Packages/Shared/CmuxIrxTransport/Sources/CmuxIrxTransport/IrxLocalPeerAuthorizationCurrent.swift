import Foundation

/// Holds the current in-memory local authorization set for synchronous admission.
///
/// No persistence or cloud lease is implied. Replacements affect subsequent
/// judgments, not already admitted connections.
// The synchronous IrxGrantJudgment seam requires a lock; every snapshot access
// is protected by it, and only immutable Sendable values escape the lock.
public final class IrxLocalPeerAuthorizationCurrent: @unchecked Sendable {
    /// A replacement rejected without changing the current snapshot.
    public enum ReplacementError: Error, Equatable, Sendable {
        /// Two entries have the same canonical endpoint key.
        case duplicateEndpointID
    }

    private let lock = NSLock()
    private var snapshot: [String: IrxLocalPeerAuthorization] = [:]

    /// Creates an empty authorization set that denies all peers.
    public init() {}

    /// An atomic value snapshot indexed by canonical endpoint key.
    public var current: [String: IrxLocalPeerAuthorization] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Atomically replaces all authorizations after validating uniqueness.
    ///
    /// - Parameter authorizations: The complete next set; an empty array clears it.
    /// - Throws: ``ReplacementError/duplicateEndpointID`` for duplicate keys,
    ///   leaving the previous snapshot unchanged.
    public func replace(_ authorizations: [IrxLocalPeerAuthorization]) throws {
        var next: [String: IrxLocalPeerAuthorization] = [:]
        for authorization in authorizations {
            guard next[authorization.endpointIDHex] == nil else {
                throw ReplacementError.duplicateEndpointID
            }
            next[authorization.endpointIDHex] = authorization
        }
        lock.lock()
        snapshot = next
        lock.unlock()
    }

    /// Clears all local authorizations for subsequent admission attempts.
    public func clear() {
        lock.lock()
        snapshot = [:]
        lock.unlock()
    }
}
