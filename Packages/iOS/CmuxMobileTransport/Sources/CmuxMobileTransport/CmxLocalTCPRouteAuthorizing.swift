@preconcurrency import Network

/// One generation of a listener's live route evidence; nil interface is test-only.
protocol CmxLocalTCPRouteAuthorizing: Sendable {
    func prepare(address: String, invalidated: @escaping @Sendable () async -> Void) async throws -> NWInterface?
    func validate(path: NWPath?, port: Int) async throws
    func stop() async
}
