import Foundation

/// System VPN path evidence, not cryptographic Tailscale node identity.
struct CmxLocalTCPRouteProof: Equatable, Sendable {
    enum Failure: Error { case unavailable }
    let localIPv4: CmxTailscaleIPAddress
    let interface: CmxNetworkInterfaceIdentity
    let localAddresses: Set<CmxTailscaleIPAddress>

    static func prepare(address: String, snapshot: CmxTailscaleAuthoritySnapshot) throws -> Self {
        guard CmxLocalTCPListenerConfiguration.isAllowedAddress(address),
              let local = CmxTailscaleIPAddress(address), snapshot.pathSatisfied else { throw Failure.unavailable }
        // Count every owner before considering whether one is currently usable.
        let owners = snapshot.systemInterfaces.filter { $0.addresses.contains(local) }
        guard owners.count == 1, let owner = owners.first,
              owner.identity.name.hasPrefix("utun"), owner.identity.index > 0,
              owner.isUp, owner.isRunning, snapshot.availableInterfaces.contains(owner.identity) else {
            throw Failure.unavailable
        }
        return Self(localIPv4: local, interface: owner.identity, localAddresses: owner.tailnetAddresses)
    }

    /// Selects a single usable tunnel and local IPv4 without guessing an address.
    static func prepareClient(peerAddress: String, snapshot: CmxTailscaleAuthoritySnapshot) throws -> Self {
        guard CmxLocalTCPListenerConfiguration.isAllowedAddress(peerAddress),
              let peer = CmxTailscaleIPAddress(peerAddress), snapshot.pathSatisfied,
              !snapshot.systemInterfaces.contains(where: { $0.addresses.contains(peer) }) else { throw Failure.unavailable }
        let candidates = snapshot.systemInterfaces.filter {
            $0.identity.name.hasPrefix("utun") && $0.identity.index > 0 && $0.isUp && $0.isRunning
                && snapshot.availableInterfaces.contains($0.identity)
                && $0.addresses.contains(where: { $0.family == .ipv4 && $0.isTailscaleAddress })
        }
        guard candidates.count == 1, let owner = candidates.first else { throw Failure.unavailable }
        let addresses = owner.addresses.filter { $0.family == .ipv4 && $0.isTailscaleAddress }
        guard addresses.count == 1, let local = addresses.first, local.isTailscalePeerAddress else { throw Failure.unavailable }
        return try prepare(address: local.bytes.map { String($0) }.joined(separator: "."), snapshot: snapshot)
    }

    /// Client validation pins the remote port, never the ephemeral local port.
    func validateClientConnection(isSatisfied: Bool, interfaces: Set<CmxNetworkInterfaceIdentity>, usesRequiredType: Bool,
                                  localAddress: CmxTailscaleIPAddress?, localPort: Int?,
                                  remoteAddress: CmxTailscaleIPAddress?, remotePort: Int?,
                                  peerAddress: String, peerPort: Int, snapshot: CmxTailscaleAuthoritySnapshot) throws {
        guard try Self.prepareClient(peerAddress: peerAddress, snapshot: snapshot) == self,
              isSatisfied, interfaces.contains(interface), usesRequiredType,
              localAddress == localIPv4, let localPort, (1...65535).contains(localPort),
              remoteAddress == CmxTailscaleIPAddress(peerAddress), remotePort == peerPort,
              (1...65535).contains(peerPort) else { throw Failure.unavailable }
    }

    func validate(address: String, snapshot: CmxTailscaleAuthoritySnapshot) throws {
        guard try Self.prepare(address: address, snapshot: snapshot) == self else { throw Failure.unavailable }
    }

    func validateConnection(isSatisfied: Bool, interfaces: Set<CmxNetworkInterfaceIdentity>, usesRequiredType: Bool,
                            localAddress: CmxTailscaleIPAddress?, localPort: Int?, expectedPort: Int,
                            remoteAddress: CmxTailscaleIPAddress?, selfAddresses: Set<CmxTailscaleIPAddress>) throws {
        guard isSatisfied, interfaces.contains(interface), usesRequiredType,
              localAddress == localIPv4, localPort == expectedPort,
              let remoteAddress, remoteAddress.family == .ipv4, remoteAddress.isTailscalePeerAddress,
              !selfAddresses.contains(remoteAddress) else { throw Failure.unavailable }
    }
}
