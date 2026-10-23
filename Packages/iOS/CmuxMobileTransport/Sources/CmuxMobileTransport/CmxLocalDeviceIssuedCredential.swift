public import Foundation

/// A newly persisted capability, returned only to the issuing caller.
///
/// Deliver only after explicit approval and verified VPN routing; never log this value.
public struct CmxLocalDeviceIssuedCredential: Sendable {
    /// The approved device's nonsecret metadata.
    public let device: CmxLocalDevice
    /// Exactly 32 cryptographically random bytes; the server stores only their digest.
    public let token: Data
}
