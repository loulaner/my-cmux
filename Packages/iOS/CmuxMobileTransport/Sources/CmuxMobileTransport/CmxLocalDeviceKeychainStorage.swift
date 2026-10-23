public import Foundation
import Security

/// Keychain storage with an explicit service and optional access group, without migration.
public actor CmxLocalDeviceKeychainStorage: CmxLocalDeviceCredentialStorage {
    /// Safe Keychain failures, excluding OSStatus descriptions or stored content.
    public enum Failure: Error, Equatable, Sendable {
        /// Service or access group is blank.
        case invalidNamespace
        /// A Keychain operation failed.
        case unavailable
    }
    private let service: String
    private let accessGroup: String?

    /// Creates storage without touching Keychain.
    /// - Parameters:
    ///   - service: Explicit nonblank service; no application-global default exists.
    ///   - accessGroup: Explicit group, or nil for the application's own group.
    /// - Throws: ``Failure/invalidNamespace`` for a blank namespace.
    public init(service: String, accessGroup: String?) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accessGroup == nil || !accessGroup!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidNamespace
        }
        self.service = service
        self.accessGroup = accessGroup
    }

    /// Reads a single scoped record without consulting legacy services.
    /// - Parameter account: The exact store-derived account key.
    /// - Returns: Stored data, or nil only for an absent item.
    /// - Throws: ``Failure/unavailable`` on all other Keychain failures.
    public func read(account: String) async throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.unavailable }
        return data
    }

    /// Replaces one item with device-only, after-first-unlock protection.
    /// - Parameters:
    ///   - data: The non-token versioned digest record.
    ///   - account: The exact store-derived account key.
    /// - Throws: ``Failure/unavailable`` if persistence fails.
    public func write(_ data: Data, account: String) async throws {
        let query = baseQuery(account: account)
        let attributes = writeAttributes(data)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw Failure.unavailable }
    }

    /// Pure query construction is testable without accessing the user's Keychain.
    nonisolated func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    nonisolated func writeAttributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }
}
