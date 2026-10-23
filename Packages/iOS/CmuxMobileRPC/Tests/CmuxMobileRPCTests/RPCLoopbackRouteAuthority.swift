@preconcurrency import Network
@testable import CmuxMobileTransport

/// Package-test-only native loopback proof; never used by the public connector initializer.
actor RPCLoopbackRouteAuthority: CmxLocalTCPClientRouteAuthorizing {
    private var port = 0
    private var stopped = false
    func prepareClient(peerAddress: String, peerPort: Int,
                       invalidated: @escaping @Sendable () async -> Void) throws -> CmxLocalTCPClientRouteBinding {
        guard peerAddress == "127.0.0.1", !stopped else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        port = peerPort
        return .init(localAddress: CmxTailscaleIPAddress("127.0.0.1")!, requiredInterface: nil)
    }
    func validateClient(path: NWPath?) throws {
        guard !stopped, let path, path.status == .satisfied,
              case let .hostPort(.ipv4(local), localPort) = path.localEndpoint,
              case let .hostPort(.ipv4(peer), remotePort) = path.remoteEndpoint,
              local == IPv4Address("127.0.0.1"), localPort.rawValue > 0,
              peer == local, Int(remotePort.rawValue) == port else { throw CmxLocalTCPRouteProof.Failure.unavailable }
    }
    func stop() { stopped = true }
}
