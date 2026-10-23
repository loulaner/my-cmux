/// An explicit local TCP binding, not proof of a VPN route or device authorization.
public struct CmxLocalTCPListenerConfiguration: Sendable {
    /// Invalid listener configuration.
    public enum ValidationError: Error, Equatable, Sendable {
        /// The address is not canonical Tailscale peer IPv4, or belongs to a reserved service range.
        case invalidAddress
        /// The port is outside 1 through 65535.
        case invalidPort
    }
    /// The exact numeric local address to bind.
    public let address: String
    /// The requested TCP port.
    public let port: Int
    let permitsLoopbackForTesting: Bool

    /// Creates an explicit listener configuration.
    /// - Parameters:
    ///   - address: Canonical IPv4 in the Tailscale peer range, excluding reserved services.
    ///   - port: A TCP port from 1 through 65535.
    /// - Throws: ``ValidationError`` for an invalid address or port.
    public init(address: String, port: Int) throws {
        guard Self.isAllowedAddress(address) else { throw ValidationError.invalidAddress }
        guard (1...65535).contains(port) else { throw ValidationError.invalidPort }
        self.address = address
        self.port = port
        permitsLoopbackForTesting = false
    }

    private init(loopbackPort: Int) {
        address = "127.0.0.1"
        port = loopbackPort
        permitsLoopbackForTesting = true
    }

    static func loopbackForTesting(port: Int = 0) -> Self { Self(loopbackPort: port) }
    static func isAllowedAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part), (0...255).contains(number), String(number) == part else { return nil }
            return number
        }
        return parts.count == 4 && octets.count == 4
            && CmxTailscaleIPAddress(value)?.isTailscalePeerAddress == true
    }

}
