import Foundation
@testable import CmuxMobileTransport

actor LocalDeviceMemoryStorage: CmxLocalDeviceCredentialStorage {
    enum Failure: Error { case unavailable }
    var records: [String: Data] = [:]
    var writes = 0
    var failRead = false
    var failWrite = false
    func failures(read: Bool = false, write: Bool = false) { failRead = read; failWrite = write }
    func corrupt(_ data: Data) { for key in records.keys { records[key] = data } }
    func read(account: String) async throws -> Data? {
        if failRead { throw Failure.unavailable }
        return records[account]
    }
    func write(_ data: Data, account: String) async throws {
        if failWrite { throw Failure.unavailable }
        records[account] = data
        writes += 1
    }
}
