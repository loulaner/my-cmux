public import Foundation
import CryptoKit
import Security

/// Owns one local device-capability scope with serialized persistence transactions.
///
/// Call load before issuing or authenticating. Own one instance per scope; this
/// queue does not coordinate multiple processes. Issuing is a primitive, not
/// user approval or proof that the network route belongs to Tailscale.
public actor CmxLocalDeviceCredentialStore {
    /// Safe errors that contain no stored data or Keychain diagnostics.
    public enum Failure: Error, Equatable, Sendable {
        /// The scope is blank.
        case invalidScope
        /// Loading must succeed before mutations are permitted.
        case notLoaded
        /// The device ID or token is invalid, absent, revoked, or unavailable.
        case invalidCredential
        /// The requested display name violates the documented limits.
        case invalidDisplayName
        /// The scope already contains 32 devices.
        case deviceLimit
        /// Stored data violates the versioned record contract.
        case invalidRecord
        /// Storage failed; a failed write does not publish the attempted change.
        case storageFailure
        /// Secure random generation failed.
        case randomnessFailure
    }

    private let storage: any CmxLocalDeviceCredentialStorage
    private let account: String
    private var current: [CmxLocalDeviceRecord] = []
    private var loaded = false
    private var tail: Task<Void, Never>?

    /// Constructs a store without storage access.
    /// - Parameters:
    ///   - storage: Explicit scoped storage dependency.
    ///   - storageScope: Nonblank opaque scope, encoded using its exact UTF-8 bytes.
    /// - Throws: ``Failure/invalidScope`` when the scope is blank.
    public init(storage: any CmxLocalDeviceCredentialStorage, storageScope: String) throws {
        guard !storageScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidScope
        }
        self.storage = storage
        account = "local-direct-devices-v1:" + storageScope.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads and validates the complete record, or an empty set when absent.
    /// - Throws: Safe storage/record failures; every failure clears authorization state.
    public func load() async throws {
        try await enqueue { try await self.loadTransaction() }
    }

    /// Issues a new capability after its digest is durably stored.
    /// - Parameter displayName: Trimmed nonempty text of at most 64 Unicode scalars, with no controls.
    /// - Returns: Nonsecret metadata and the new token, never cached by this store.
    /// - Throws: Validation, capacity, randomness, or persistence errors.
    public func issueDevice(displayName: String) async throws -> CmxLocalDeviceIssuedCredential {
        try await enqueue { try await self.issueTransaction(displayName) }
    }

    /// Removes a device only after the replacement list is durably written.
    /// - Parameter deviceID: The previously issued identifier.
    /// - Returns: True if a record was removed; unknown/already revoked IDs return false without writing.
    /// - Throws: Not-loaded or write failure; a failed write is not durable revocation.
    public func revoke(deviceID: String) async throws -> Bool {
        try await enqueue { try await self.revokeTransaction(deviceID) }
    }

    /// Authenticates against the current loaded record using fixed-size digest comparison.
    /// - Parameters:
    ///   - deviceID: The server-issued identifier.
    ///   - token: Exactly 32 capability bytes.
    /// - Returns: Nonsecret metadata; this does not establish route/interface proof.
    /// - Throws: ``Failure/invalidCredential`` for all authentication failures.
    public func authenticate(deviceID: String, token: Data) async throws -> CmxLocalDevice {
        try await enqueue { try await self.authenticateTransaction(deviceID, token: token) }
    }

    /// Returns only nonsecret metadata from the latest published snapshot.
    /// - Returns: No devices before successful load or after a load failure.
    public func devices() -> [CmxLocalDevice] { current.map(\.device) }

    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; return try await operation() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func loadTransaction() async throws {
        do {
            let data: Data?
            do { data = try await storage.read(account: account) } catch { throw Failure.storageFailure }
            var entries: [CmxLocalDeviceRecord] = []
            if let data {
                guard let record = try? JSONDecoder().decode(CmxLocalDeviceCredentialRecord.self, from: data),
                      record.version == 1, record.devices.count <= 32 else { throw Failure.invalidRecord }
                var ids: Set<String> = []
                for entry in record.devices {
                    guard let uuid = UUID(uuidString: entry.deviceID), uuid.uuidString.lowercased() == entry.deviceID,
                          ids.insert(entry.deviceID).inserted, entry.digest.count == 32,
                          Self.validName(entry.displayName),
                          entry.displayName == entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { throw Failure.invalidRecord }
                }
                entries = record.devices
            }
            current = entries
            loaded = true
        } catch {
            current = []
            loaded = false
            throw error
        }
    }

    private func issueTransaction(_ name: String) async throws -> CmxLocalDeviceIssuedCredential {
        guard loaded else { throw Failure.notLoaded }
        // Controls are rejected before trimming, so a newline is never silently accepted.
        guard Self.validName(name) else { throw Failure.invalidDisplayName }
        guard current.count < 32 else { throw Failure.deviceLimit }
        var token = Data(count: 32)
        let status = token.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.randomnessFailure }
        let entry = CmxLocalDeviceRecord(deviceID: UUID().uuidString.lowercased(),
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines), digest: Data(SHA256.hash(data: token)))
        try await persist(current + [entry])
        return CmxLocalDeviceIssuedCredential(device: entry.device, token: token)
    }

    private func revokeTransaction(_ id: String) async throws -> Bool {
        guard loaded else { throw Failure.notLoaded }
        guard current.contains(where: { $0.deviceID == id }) else { return false }
        try await persist(current.filter { $0.deviceID != id })
        return true
    }

    private func authenticateTransaction(_ id: String, token: Data) throws -> CmxLocalDevice {
        guard loaded, token.count == 32 else { throw Failure.invalidCredential }
        let digest = Data(SHA256.hash(data: token))
        let entry = current.first { $0.deviceID == id }
        let expected = entry?.digest ?? Data(repeating: 0, count: 32)
        var difference: UInt8 = 0
        for (a, b) in zip(digest, expected) { difference |= a ^ b }
        guard difference == 0, let entry else { throw Failure.invalidCredential }
        return entry.device
    }

    private func persist(_ entries: [CmxLocalDeviceRecord]) async throws {
        do {
            let data = try JSONEncoder().encode(CmxLocalDeviceCredentialRecord(version: 1, devices: entries))
            try await storage.write(data, account: account)
        } catch { throw Failure.storageFailure }
        current = entries
    }

    static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.unicodeScalars.count <= 64
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
