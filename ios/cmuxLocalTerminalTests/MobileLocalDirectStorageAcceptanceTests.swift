#if os(iOS)
import CmuxMobileShell
import Darwin
import Foundation
import Testing

/// Real app-sandbox storage, isolated from the production credential path.
@Suite
struct MobileLocalDirectStorageAcceptanceTests {
    @Test func protectedSandboxRoundTrip() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        let directory = home.appendingPathComponent("Library/Application Support")
            .appendingPathComponent("storage-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLocalDirectClientFileStore(baseURL: directory)
        #expect(try await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let record = try MobileLocalDirectClientRecord(host: "100.64.0.1", port: 49443,
            hostID: "00000000-0000-0000-0000-000000000001",
            deviceID: "00000000-0000-0000-0000-000000000002", token: Data(repeating: 17, count: 32))
        try await store.save(record)
        let file = directory.appendingPathComponent("client-v1.json")
        for (url, mode) in [(directory, 0o700), (file, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue
                ?? (attributes[.protectionKey] as? String)
            #expect(protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        let reopened = MobileLocalDirectClientFileStore(baseURL: directory)
        #expect(try await reopened.load() == record)
        try await reopened.forget()
        #expect(try await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
