@preconcurrency import Network

/// Client-only proof lifecycle. Server local-port validation is intentionally a separate contract.
protocol CmxLocalTCPClientRouteAuthorizing: Sendable {
    func prepareClient(peerAddress: String, peerPort: Int,
                       invalidated: @escaping @Sendable () async -> Void) async throws -> CmxLocalTCPClientRouteBinding
    func validateClient(path: NWPath?) async throws
    func stop() async
}
