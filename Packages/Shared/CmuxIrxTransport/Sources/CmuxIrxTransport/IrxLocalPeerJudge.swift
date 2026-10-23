/// Judges TLS-authenticated peers solely against injected local authorizations.
///
/// Hello grants carry no authority. This judge performs no network or disk I/O
/// and does not establish pairing or terminate existing connections.
///
/// ```swift
/// let current = IrxLocalPeerAuthorizationCurrent()
/// let judgment = IrxLocalPeerJudge(current: current).judgment()
/// // Replace current's authorizations before admitting a locally paired peer.
/// ```
public struct IrxLocalPeerJudge: Sendable {
    private let current: IrxLocalPeerAuthorizationCurrent

    /// Creates a judge using an explicitly owned authorization set.
    ///
    /// - Parameter current: The live set read on every judgment invocation.
    public init(current: IrxLocalPeerAuthorizationCurrent) {
        self.current = current
    }

    /// Creates a synchronous judgment that observes later snapshot replacements.
    ///
    /// - Returns: A closure ignoring the grant and requiring a known, valid TLS
    ///   endpoint; it throws ``IrxAdmissionDenied`` for unknown, invalid, or revoked peers.
    public func judgment() -> IrxGrantJudgment {
        let current = current
        return { _, remoteEndpointIDHex in
            guard let key = try? IrxLocalPeerAuthorization.normalizedEndpointID(remoteEndpointIDHex),
                  let authorization = current.current[key] else {
                throw IrxAdmissionDenied(code: .invalidGrant)
            }
            guard !authorization.revoked else { throw IrxAdmissionDenied(code: .revoked) }
            return IrxAdmittedPeerInfo(
                bindingID: authorization.bindingID, deviceID: authorization.deviceID,
                tag: authorization.tag, endpointIDHex: authorization.endpointIDHex,
                identityGeneration: authorization.identityGeneration
            )
        }
    }
}
