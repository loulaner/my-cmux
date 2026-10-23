import Foundation
import Testing
@testable import CmuxMobileShell

struct MobileLocalDirectClientRecordTests {
    @Test(arguments: ["host", "port", "hostID", "deviceID", "token"])
    func invalidRecordCannotBeRemembered(_ field: String) {
        #expect(throws: (any Error).self) {
            try MobileLocalDirectClientRecord(host: field == "host" ? "localhost" : "100.70.1.2", port: field == "port" ? 0 : 49443,
                hostID: field == "hostID" ? "" : UUID().uuidString, deviceID: field == "deviceID" ? "bad" : UUID().uuidString.lowercased(),
                token: Data(repeating: 42, count: field == "token" ? 31 : 32))
        }
    }
}
