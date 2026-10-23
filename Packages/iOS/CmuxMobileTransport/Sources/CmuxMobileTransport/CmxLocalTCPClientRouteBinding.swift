@preconcurrency import Network

/// Native binding from a proven route; a nil interface is only supplied by internal loopback fixtures.
struct CmxLocalTCPClientRouteBinding: Sendable {
    let localAddress: CmxTailscaleIPAddress
    let requiredInterface: NWInterface?
}
