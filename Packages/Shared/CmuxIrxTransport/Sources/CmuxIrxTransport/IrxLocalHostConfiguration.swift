/// A strict local host binding restricted to the Tailscale IPv4 address range.
public struct IrxLocalHostConfiguration: Sendable {
    /// A rejected local listener configuration.
    public enum ValidationError: Error, Equatable, Sendable {
        /// The address is not canonical IPv4 within 100.64.0.0/10.
        case invalidAddress
        /// The port is outside 1 through 65535.
        case invalidPort
    }

    /// The injected TLS identity, never loaded from global state.
    public let identity: IrxIdentity
    /// The exact local interface address to bind.
    public let address: String
    /// The requested UDP port.
    public let port: Int

    /// Validates an explicit VPN listener address and port.
    ///
    /// - Parameters:
    ///   - identity: The host's TLS identity.
    ///   - address: Canonical four-component decimal IPv4 in 100.64.0.0/10.
    ///   - port: A UDP port from 1 through 65535.
    /// - Throws: ``ValidationError`` for an invalid address or port.
    public init(identity: IrxIdentity, address: String, port: Int) throws {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), (0...255).contains(value), String(value) == part else { return nil }
            return value
        }
        guard parts.count == 4, numbers.count == 4, numbers[0] == 100, (64...127).contains(numbers[1]) else {
            throw ValidationError.invalidAddress
        }
        guard (1...65535).contains(port) else { throw ValidationError.invalidPort }
        self.identity = identity
        self.address = address
        self.port = port
    }

    private init(loopbackIdentity: IrxIdentity) {
        identity = loopbackIdentity
        address = "127.0.0.1"
        port = 0
    }

    /// Test-only internal construction; never broadens public VPN validation.
    static func loopbackForTesting(identity: IrxIdentity) -> Self {
        Self(loopbackIdentity: identity)
    }

    var endpointConfiguration: IrxEndpointConfiguration {
        IrxEndpointConfiguration(identity: identity, pathMode: .directOnly,
            preferredBindAddress: "\(address):\(port)", initialRemoteBiStreams: 1,
            initialRemoteUniStreams: 0, allowsPreferredBindFallback: false)
    }
}
