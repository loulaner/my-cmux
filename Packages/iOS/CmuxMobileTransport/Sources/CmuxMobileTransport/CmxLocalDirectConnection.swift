import CMUXMobileCore
import Foundation
@preconcurrency import Network

/// Owns a single attempt and its monitor. Invalidation holds only a weak reference back.
actor CmxLocalDirectConnection {
    private let authority: any CmxLocalTCPClientRouteAuthorizing
    private let timeout: UInt64
    private var base: CmxNetworkByteTransport?
    private var connection: NWConnection?
    private var closed = false

    init(authority: any CmxLocalTCPClientRouteAuthorizing, timeout: UInt64) {
        self.authority = authority
        self.timeout = timeout
    }

    func connect(host: String, port: Int) async throws -> any CmxByteTransport {
        guard !closed else { throw CancellationError() }
        let binding: CmxLocalTCPClientRouteBinding
        do {
            binding = try await authority.prepareClient(peerAddress: host, peerPort: port) { [weak self] in
                await self?.close()
            }
        } catch { throw CmxLocalDirectConnector.Failure.vpnUnavailable }
        try Task.checkCancellation()
        guard !closed, let peer = IPv4Address(host), let nativePort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0) else {
            throw CmxLocalDirectConnector.Failure.vpnUnavailable
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterface = binding.requiredInterface
        parameters.requiredLocalEndpoint = .hostPort(host: binding.localAddress.nwHost, port: .any)
        let connection = NWConnection(host: .ipv4(peer), port: nativePort, using: parameters)
        self.connection = connection
        let base = try CmxNetworkByteTransport(acceptedConnection: connection,
            maximumReceiveLength: CmxNetworkByteTransport.defaultMaximumReceiveLength, connectTimeoutNanoseconds: timeout)
        self.base = base
        do { try await base.connect() }
        catch { throw CmxLocalDirectConnector.Failure.connectionFailed }
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
        return CmxLocalTCPGuardedTransport(base: base, onClose: { await self.close() }) {
            try await self.validate()
        }
    }

    private func validate() async throws {
        guard !closed, let connection else { throw CmxLocalDirectConnector.Failure.vpnUnavailable }
        do { try await authority.validateClient(path: connection.currentPath) }
        catch {
            await close()
            throw CmxLocalDirectConnector.Failure.vpnUnavailable
        }
        guard !closed else { throw CmxLocalDirectConnector.Failure.vpnUnavailable }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        let base = base
        self.base = nil
        await base?.close()
        await authority.stop()
    }
}
