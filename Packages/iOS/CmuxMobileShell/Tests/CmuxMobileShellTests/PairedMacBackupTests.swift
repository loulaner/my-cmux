import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct PairedMacBackupTests {
    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func route(_ host: String, _ port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }

    @Test func setCustomizationPersistsAndPreservesMacData() async throws {
        let (inner, dir) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await inner.upsert(
            macDeviceID: "mac-a", displayName: "Mini",
            routes: [try route("10.0.0.1", 22)], markActive: true,
            stackUserID: "user-1", now: Date(timeIntervalSince1970: 1_000)
        )
        try await inner.setCustomization(
            macDeviceID: "mac-a", customName: "Studio", customColor: "#FF8800",
            customIcon: "desktopcomputer", stackUserID: "user-1", teamID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let mac = try await inner.loadAll(stackUserID: "user-1").first
        #expect(mac?.customName == "Studio")
        #expect(mac?.customColor == "#FF8800")
        #expect(mac?.customIcon == "desktopcomputer")
        // setCustomization leaves the Mac's reported name + routes + active intact.
        #expect(mac?.displayName == "Mini")
        #expect(mac?.isActive == true)
        #expect(mac?.routes.count == 1)
    }
}
