import Foundation
import Security
import Testing
@testable import CmuxMobileTransport

struct CmxLocalDeviceKeychainStorageTests {
    @Test func namespaceAndProtectionQueriesWithoutKeychainIO() throws {
        let one = try CmxLocalDeviceKeychainStorage(service: "synthetic.one", accessGroup: nil)
        let two = try CmxLocalDeviceKeychainStorage(service: "synthetic.two", accessGroup: "synthetic.group")
        let first = one.baseQuery(account: "local-direct-devices-v1:61")
        let second = two.baseQuery(account: "local-direct-devices-v1:61")
        #expect(first[kSecAttrService as String] as? String == "synthetic.one")
        #expect(second[kSecAttrService as String] as? String == "synthetic.two")
        #expect(first[kSecAttrAccessGroup as String] == nil)
        #expect(second[kSecAttrAccessGroup as String] as? String == "synthetic.group")
        #expect(first[kSecAttrAccount as String] as? String == "local-direct-devices-v1:61")
        #expect(first[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(first[kSecAttrSynchronizable as String] as? Bool == false)
        let payload = Data("synthetic-record".utf8)
        let attributes = one.writeAttributes(payload)
        #expect(attributes[kSecValueData as String] as? Data == payload)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(throws: CmxLocalDeviceKeychainStorage.Failure.invalidNamespace) {
            try CmxLocalDeviceKeychainStorage(service: " ", accessGroup: nil)
        }
    }
}
