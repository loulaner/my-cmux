import CmuxCloud
import Foundation
import Testing

@Suite struct MacPairedMacBackupRecordWireTests {
    @Test func publisherRecordCarriesCompareAndSetInstanceAuthority() throws {
        let record = MacPairedMacBackupRecordWire(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            instanceTag: "feature-a",
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true
        )
        let json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)
        ) as? [String: Any])

        #expect(json["instanceTag"] as? String == "feature-a")
        #expect(json["instanceTagWriteMode"] as? String == "compare_and_set")
    }
}
