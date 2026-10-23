import Foundation
import CmuxMobileTransport

/// Isolated capability digest storage for the native framing peer.
actor RPCDirectMemoryStorage: CmxLocalDeviceCredentialStorage {
    private var records: [String: Data] = [:]
    func read(account: String) -> Data? { records[account] }
    func write(_ data: Data, account: String) { records[account] = data }
}
