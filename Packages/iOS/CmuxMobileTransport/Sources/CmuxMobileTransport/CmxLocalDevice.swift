/// Nonsecret metadata for an approved local device.
public struct CmxLocalDevice: Equatable, Sendable {
    /// A server-generated canonical lowercase UUID.
    public let deviceID: String
    /// Untrusted display text, trimmed and limited to 64 Unicode scalars without controls.
    public let displayName: String
}
