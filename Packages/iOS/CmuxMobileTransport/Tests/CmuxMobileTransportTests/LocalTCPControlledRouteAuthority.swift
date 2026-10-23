import Foundation
@preconcurrency import Network
@testable import CmuxMobileTransport

actor LocalTCPControlledRouteAuthority: CmxLocalTCPRouteAuthorizing {
    let permitsStartup: Bool
    let loopback = CmxLocalTCPLoopbackRouteAuthority()
    var callback: (@Sendable () async -> Void)?
    var revoked = false
    init(permitsStartup: Bool = true) { self.permitsStartup = permitsStartup }
    func prepare(address: String, invalidated: @escaping @Sendable () async -> Void) async throws -> NWInterface? {
        callback = invalidated
        guard permitsStartup else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        return try await loopback.prepare(address: address, invalidated: invalidated)
    }
    func validate(path: NWPath?, port: Int) async throws {
        guard !revoked else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        try await loopback.validate(path: path, port: port)
    }
    func revoke() async {
        revoked = true
        await callback?()
    }
    func stop() async { revoked = true; await loopback.stop() }
}
