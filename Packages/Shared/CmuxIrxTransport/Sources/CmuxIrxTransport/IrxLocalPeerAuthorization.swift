import Foundation

/// An immutable local authorization bound to a TLS-authenticated endpoint key.
public struct IrxLocalPeerAuthorization: Equatable, Sendable {
    /// Invalid input rejected before an authorization can enter a snapshot.
    public enum ValidationError: Error, Equatable, Sendable {
        /// The endpoint is not exactly 64 ASCII hexadecimal characters.
        case invalidEndpointID
        /// A binding, device, or tag is empty after trimming whitespace.
        case emptyIdentityField
        /// The identity generation is less than one.
        case invalidIdentityGeneration
    }

    /// The canonical lowercase endpoint key, with exactly 64 ASCII hex digits.
    public let endpointIDHex: String
    /// The nonempty, whitespace-trimmed local binding identifier.
    public let bindingID: String
    /// The nonempty, whitespace-trimmed local device identifier.
    public let deviceID: String
    /// The nonempty, whitespace-trimmed local instance tag.
    public let tag: String
    /// The positive identity generation assigned by local authorization.
    public let identityGeneration: Int
    /// Whether subsequent admission attempts must be denied as revoked.
    public let revoked: Bool

    /// Validates and normalizes a local authorization without external state.
    ///
    /// - Parameters:
    ///   - endpointIDHex: Exactly 64 ASCII hexadecimal digits; case is normalized.
    ///   - bindingID: A nonempty binding identifier after whitespace trimming.
    ///   - deviceID: A nonempty device identifier after whitespace trimming.
    ///   - tag: A nonempty instance tag after whitespace trimming.
    ///   - identityGeneration: A generation of at least one.
    ///   - revoked: Whether the authorization explicitly denies admission.
    /// - Throws: ``ValidationError`` when any invariant is violated.
    public init(
        endpointIDHex: String, bindingID: String, deviceID: String, tag: String,
        identityGeneration: Int, revoked: Bool
    ) throws {
        self.endpointIDHex = try Self.normalizedEndpointID(endpointIDHex)
        let bindingID = bindingID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bindingID.isEmpty, !deviceID.isEmpty, !tag.isEmpty else {
            throw ValidationError.emptyIdentityField
        }
        guard identityGeneration >= 1 else { throw ValidationError.invalidIdentityGeneration }
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.tag = tag
        self.identityGeneration = identityGeneration
        self.revoked = revoked
    }

    /// Applies the same strict key validation to stored and TLS-proved keys.
    static func normalizedEndpointID(_ value: String) throws -> String {
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw ValidationError.invalidEndpointID }
        return value.lowercased()
    }
}
