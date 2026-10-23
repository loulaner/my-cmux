import Foundation
import CmuxMobileTransport
@testable import CmuxMobileShell

/// Counts admission attempts independently of dialing; no credentials are printed.
actor DirectAdmissionRetryFixture {
    let failure: CmxLocalDirectAdmission.Failure
    private(set) var attempts = 0
    private(set) var pairAttempts = 0
    init(_ failure: CmxLocalDirectAdmission.Failure) { self.failure = failure }
    func admit(record: MobileLocalDirectClientRecord?, rpc: MobileDirectClientFixture) async throws -> MobileLocalDirectClientConnection {
        attempts += 1
        if record == nil { pairAttempts += 1 }
        if attempts == 1 { throw failure }
        return try await rpc.admit()
    }
}
