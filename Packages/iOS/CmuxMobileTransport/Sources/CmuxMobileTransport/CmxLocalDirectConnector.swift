public import CMUXMobileCore
import Foundation

/// Creates one unauthenticated, VPN-proven TCP stream per explicit connection attempt.
///
/// Construction has no network or storage side effects. After connecting, the caller
/// must explicitly pair or authenticate using ``CmxLocalDirectAdmission``, and close
/// the returned transport when finished. There is no retry, DNS, relay, or token store.
public struct CmxLocalDirectConnector: Sendable {
    /// Safe connection failures that never include an address or credential.
    public enum Failure: Error, Equatable, Sendable {
        /// Destination is not a canonical peer IPv4 and TCP port.
        case invalidDestination
        /// A unique live VPN route or its effective endpoints could not be proven.
        case vpnUnavailable
        /// Native TCP readiness failed or exceeded its bounded deadline.
        case connectionFailed
    }

    private let makeAuthority: @Sendable () -> any CmxLocalTCPClientRouteAuthorizing
    private let permitsLoopbackForTesting: Bool
    private let connectTimeoutNanoseconds: UInt64

    /// Creates a connector with ten-second route and fifteen-second TCP readiness limits.
    public init() {
        makeAuthority = { CmxLocalTCPSystemRouteAuthority() }
        permitsLoopbackForTesting = false
        connectTimeoutNanoseconds = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    }

    /// Internal fixtures cannot widen the public destination contract.
    init(makeAuthority: @escaping @Sendable () -> any CmxLocalTCPClientRouteAuthorizing,
         permitsLoopbackForTesting: Bool = false,
         connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds) {
        self.makeAuthority = makeAuthority
        self.permitsLoopbackForTesting = permitsLoopbackForTesting
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
    }

    /// Connects only after proving the local VPN binding, then validates the ready path.
    /// - Parameters:
    ///   - host: Exact canonical Tailscale peer IPv4, excluding service and self addresses.
    ///   - port: Exact remote port in `1...65535`.
    /// - Returns: A connected byte stream; no authentication material has been sent.
    /// - Throws: ``Failure`` or `CancellationError`. Cancellation releases the attempt.
    public func connect(host: String, port: Int) async throws -> any CmxByteTransport {
        guard (1...65535).contains(port), CmxLocalTCPListenerConfiguration.isAllowedAddress(host)
                || (permitsLoopbackForTesting && host == "127.0.0.1") else { throw Failure.invalidDestination }
        try Task.checkCancellation()
        let attempt = CmxLocalDirectConnection(authority: makeAuthority(), timeout: connectTimeoutNanoseconds)
        return try await withTaskCancellationHandler {
            do {
                return try await attempt.connect(host: host, port: port)
            } catch {
                await attempt.close()
                if Task.isCancelled { throw CancellationError() }
                throw (error as? Failure) ?? Failure.connectionFailed
            }
        } onCancel: { Task { await attempt.close() } }
    }
}
