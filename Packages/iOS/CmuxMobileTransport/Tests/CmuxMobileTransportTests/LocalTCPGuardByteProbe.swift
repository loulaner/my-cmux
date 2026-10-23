import CMUXMobileCore
import Foundation
@testable import CmuxMobileTransport

/// Models evidence disappearing while a native receive is in flight.
actor LocalTCPGuardByteProbe: CmxByteTransport {
    var valid = true
    var sends = 0
    var closed = false
    func connect() {}
    func receive() -> Data? {
        valid = false
        return Data("must-not-escape".utf8)
    }
    func send(_ data: Data) { sends += 1 }
    func close() { closed = true }
    func check() throws {
        guard valid else { throw CmxLocalTCPRouteProof.Failure.unavailable }
    }
}
