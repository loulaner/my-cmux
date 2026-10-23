import Foundation
import CmuxMobileTransport

/// Isolated native-framing peer digest storage; never touches real device credentials.
actor ShellDirectMemoryStorage: CmxLocalDeviceCredentialStorage {
    private var records: [String: Data] = [:]
    func read(account: String) -> Data? { records[account] }
    func write(_ data: Data, account: String) { records[account] = data }
}
