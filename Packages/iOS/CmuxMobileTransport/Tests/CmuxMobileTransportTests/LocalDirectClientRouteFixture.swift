import Foundation
@preconcurrency import Network
@testable import CmuxMobileTransport

/// Internal loopback proof, with deterministic barriers for preparation and ready validation.
actor LocalDirectClientRouteFixture: CmxLocalTCPClientRouteAuthorizing {
    let events = AsyncStream<String>.makeStream()
    private var invalidated: (@Sendable () async -> Void)?
    private var barrier: CheckedContinuation<Void, any Error>?
    private var closed = false
    private let hold: String?
    private let reject: Bool
    private(set) var prepares = 0
    private(set) var stops = 0
    private(set) var validations = 0
    private var port = 0

    init(hold: String? = nil, reject: Bool = false) { self.hold = hold; self.reject = reject }

    func prepareClient(peerAddress: String, peerPort: Int,
                       invalidated: @escaping @Sendable () async -> Void) async throws -> CmxLocalTCPClientRouteBinding {
        prepares += 1
        self.invalidated = invalidated
        port = peerPort
        try await wait("prepare")
        guard !closed, !reject else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        return .init(localAddress: CmxTailscaleIPAddress("127.0.0.1")!, requiredInterface: nil)
    }

    func validateClient(path: NWPath?) async throws {
        validations += 1
        try await wait("validate")
        guard !closed, let path, path.status == .satisfied,
              case let .hostPort(.ipv4(local), localPort) = path.localEndpoint,
              case let .hostPort(.ipv4(remote), remotePort) = path.remoteEndpoint,
              local == IPv4Address("127.0.0.1"), localPort.rawValue > 0,
              remote == IPv4Address("127.0.0.1"), Int(remotePort.rawValue) == port else {
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
    }

    private func wait(_ phase: String) async throws {
        if hold == phase {
            try await withCheckedThrowingContinuation { continuation in
                barrier = continuation
                events.continuation.yield(phase)
            }
        } else { events.continuation.yield(phase) }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        stops += 1
        invalidated = nil
        let continuation = barrier
        barrier = nil
        continuation?.resume(throwing: CmxLocalTCPRouteProof.Failure.unavailable)
        events.continuation.finish()
    }

    func revoke() async {
        let callback = invalidated
        stop()
        await callback?()
    }
}
