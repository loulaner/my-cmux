import Foundation
public import CmuxIrohTransport

/// Persists local peer authorizations through an injected secure credential store.
///
/// Own one store per scope and route mutations of its injected current snapshot
/// exclusively through this store. Transactions execute in actor enqueue order,
/// including across suspension points. Caller cancellation does not cancel a
/// queued or started transaction. No keys, pairing secrets, or cloud tokens are stored.
///
/// ```swift
/// let current = IrxLocalPeerAuthorizationCurrent()
/// let store = try IrxLocalPeerAuthorizationStore(
///     secureStore: secureStore, storageScope: "local-installation", current: current)
/// try await store.load()
/// ```
public actor IrxLocalPeerAuthorizationStore {
    /// Invalid configuration or an unsupported persisted record.
    public enum StoreError: Error, Equatable, Sendable {
        /// The storage scope contains no non-whitespace characters.
        case emptyScope
        /// The record version is not supported by this implementation.
        case unsupportedVersion
    }

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let account: String
    private let current: IrxLocalPeerAuthorizationCurrent
    private var tail: Task<Void, Never>?

    /// Creates a store without reading or publishing any authorizations.
    ///
    /// - Parameters:
    ///   - secureStore: The only persistence dependency.
    ///   - storageScope: An opaque nonblank scope, encoded exactly as UTF-8 hex.
    ///   - current: The shared admission snapshot, not a second authority source.
    /// - Throws: ``StoreError/emptyScope`` for a blank scope.
    public init(secureStore: any CmxIrohSecureCredentialStoring, storageScope: String,
                current: IrxLocalPeerAuthorizationCurrent) throws {
        guard !storageScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyScope
        }
        self.secureStore = secureStore
        self.current = current
        account = "local-peer-authorization-v1:" + storageScope.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads a validated record, or publishes an empty set when no record exists.
    ///
    /// - Throws: Read, decoding, version, field, or duplicate errors. Every failure
    ///   clears admission permissions without overwriting the stored record.
    public func load() async throws {
        try await enqueue { try await self.loadTransaction() }
    }

    /// Persists a complete authorization set before publishing it to admission.
    ///
    /// - Parameter authorizations: The complete next set with unique endpoint keys.
    /// - Throws: Duplicate or write errors, leaving the previous snapshot unchanged.
    public func replace(_ authorizations: [IrxLocalPeerAuthorization]) async throws {
        try await enqueue { try await self.replaceTransaction(authorizations) }
    }

    /// Persists revocation of an existing endpoint without changing its tuple.
    ///
    /// - Parameter endpointIDHex: A valid endpoint key, in either hex case.
    /// - Returns: Whether an active entry changed; unknown or already revoked keys return false.
    /// - Throws: Invalid-key or persistence errors; a write failure preserves the snapshot.
    public func revoke(endpointIDHex: String) async throws -> Bool {
        try await enqueue { try await self.revokeTransaction(endpointIDHex) }
    }

    /// Clears admission permissions when this transaction starts, then deletes storage.
    ///
    /// Earlier queued transactions finish first. A failed deletion keeps memory
    /// empty but may leave an old record readable after restart or another load.
    /// This error must not be reported as successful durable revocation.
    /// - Throws: Deletion errors, with admission permissions remaining empty.
    public func clear() async throws {
        try await enqueue { try await self.clearTransaction() }
    }

    /// Chains unstructured tasks so caller cancellation cannot interrupt a transaction.
    private func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tail
        let transaction = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await transaction.value }
        return try await transaction.value
    }

    private func loadTransaction() async throws {
        do {
            let values: [IrxLocalPeerAuthorization]
            if let data = try await secureStore.read(account: account) {
                values = try JSONDecoder().decode(IrxLocalPeerAuthorizationRecord.self, from: data).validated()
            } else {
                values = []
            }
            try current.replace(values)
        } catch {
            current.clear()
            throw error
        }
    }

    private func replaceTransaction(_ values: [IrxLocalPeerAuthorization]) async throws {
        var keys: Set<String> = []
        for value in values {
            guard keys.insert(value.endpointIDHex).inserted else {
                throw IrxLocalPeerAuthorizationCurrent.ReplacementError.duplicateEndpointID
            }
        }
        let data = try JSONEncoder().encode(IrxLocalPeerAuthorizationRecord(values))
        try await secureStore.write(data, account: account, accessibility: .afterFirstUnlockThisDeviceOnly)
        try current.replace(values)
    }

    private func revokeTransaction(_ endpoint: String) async throws -> Bool {
        let key = try IrxLocalPeerAuthorization.normalizedEndpointID(endpoint)
        var values = current.current
        guard let entry = values[key], !entry.revoked else { return false }
        values[key] = try IrxLocalPeerAuthorization(endpointIDHex: entry.endpointIDHex,
            bindingID: entry.bindingID, deviceID: entry.deviceID, tag: entry.tag,
            identityGeneration: entry.identityGeneration, revoked: true)
        try await replaceTransaction(Array(values.values))
        return true
    }

    private func clearTransaction() async throws {
        current.clear()
        try await secureStore.delete(account: account)
    }
}
