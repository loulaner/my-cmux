import Foundation
import CryptoKit
public import CmuxIrohTransport

/// Owns persistence of one local host identity without any account association.
///
/// Own one instance per scope. Every call reads storage afresh; no cached identity
/// masks read failures. Transactions are serialized across suspension points and
/// caller cancellation never interrupts a queued or started transaction.
/// Separate store instances for the same scope must not create concurrently.
public actor IrxLocalIdentityStore {
    /// Safe identity storage errors that never contain private-key data.
    public enum StoreError: Error, Equatable, Sendable {
        /// The opaque scope is blank.
        case emptyScope
        /// The stored record is malformed or contains an invalid identity.
        case invalidRecord
        /// The stored record version is not supported.
        case unsupportedVersion
    }

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let account: String
    private var tail: Task<Void, Never>?

    /// Constructs a store without accessing storage.
    /// - Parameters:
    ///   - secureStore: The only persistence dependency.
    ///   - storageScope: An opaque nonblank scope; its exact UTF-8 bytes define the key.
    /// - Throws: ``StoreError/emptyScope`` for blank scopes.
    public init(secureStore: any CmxIrohSecureCredentialStoring, storageScope: String) throws {
        guard !storageScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyScope
        }
        self.secureStore = secureStore
        account = "local-host-identity-v1:" + storageScope.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads an existing identity or durably creates one when storage is absent.
    /// - Returns: The validated, persisted identity.
    /// - Throws: Storage or record errors, never silently replacing invalid data.
    public func loadOrCreate() async throws -> IrxIdentity {
        let previous = tail
        let transaction = Task {
            await previous?.value
            return try await self.loadOrCreateTransaction()
        }
        tail = Task { _ = try? await transaction.value }
        return try await transaction.value
    }

    private func loadOrCreateTransaction() async throws -> IrxIdentity {
        if let data = try await secureStore.read(account: account) {
            let record: IrxLocalIdentityRecord
            do {
                record = try JSONDecoder().decode(IrxLocalIdentityRecord.self, from: data)
            } catch {
                // Decoding diagnostics can contain stored content; expose only a safe category.
                throw StoreError.invalidRecord
            }
            return try record.validatedIdentity()
        }
        let identity = IrxIdentity(privateKeyData: Curve25519.Signing.PrivateKey().rawRepresentation,
            deviceID: UUID().uuidString.lowercased(), appInstanceID: UUID().uuidString.lowercased())
        let data = try JSONEncoder().encode(IrxLocalIdentityRecord(identity))
        try await secureStore.write(data, account: account, accessibility: .afterFirstUnlockThisDeviceOnly)
        return identity
    }
}
