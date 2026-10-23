import CmuxMobileTransport
import Foundation

/// Synthetic scoped persistence; tests never instantiate a Keychain adapter.
actor MobileLocalDirectMemoryStorage: CmxLocalDeviceCredentialStorage {
    private var records: [String: Data] = [:]
    func read(account: String) async throws -> Data? { records[account] }
    func write(_ data: Data, account: String) async throws { records[account] = data }
}
