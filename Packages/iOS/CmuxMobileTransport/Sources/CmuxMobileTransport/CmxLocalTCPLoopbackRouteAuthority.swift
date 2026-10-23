@preconcurrency import Network

/// Internal-only authority for synthetic loopback tests; never accepts a product address.
actor CmxLocalTCPLoopbackRouteAuthority: CmxLocalTCPRouteAuthorizing {
    private var active = false
    func prepare(address: String, invalidated: @escaping @Sendable () async -> Void) async throws -> NWInterface? {
        guard address == "127.0.0.1" else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        active = true
        return nil
    }
    func validate(path: NWPath?, port: Int) async throws {
        guard active, let path, path.status == .satisfied,
              case let .hostPort(.ipv4(local), localPort) = path.localEndpoint,
              case let .hostPort(.ipv4(remote), _) = path.remoteEndpoint,
              local == IPv4Address("127.0.0.1"), remote == local, Int(localPort.rawValue) == port else {
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
    }
    func stop() { active = false }
}
