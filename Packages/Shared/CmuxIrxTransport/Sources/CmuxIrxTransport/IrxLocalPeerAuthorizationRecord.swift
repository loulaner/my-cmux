import Foundation

/// Versioned storage DTO; decoded fields always pass through authorization validation.
struct IrxLocalPeerAuthorizationRecord: Codable {
    struct Entry: Codable {
        let endpointIDHex: String
        let bindingID: String
        let deviceID: String
        let tag: String
        let identityGeneration: Int
        let revoked: Bool

        init(_ value: IrxLocalPeerAuthorization) {
            endpointIDHex = value.endpointIDHex
            bindingID = value.bindingID
            deviceID = value.deviceID
            tag = value.tag
            identityGeneration = value.identityGeneration
            revoked = value.revoked
        }

        func validated() throws -> IrxLocalPeerAuthorization {
            try IrxLocalPeerAuthorization(endpointIDHex: endpointIDHex, bindingID: bindingID,
                deviceID: deviceID, tag: tag, identityGeneration: identityGeneration, revoked: revoked)
        }
    }

    let version: Int
    let entries: [Entry]

    init(_ values: [IrxLocalPeerAuthorization]) {
        version = 1
        entries = values.sorted { $0.endpointIDHex < $1.endpointIDHex }.map(Entry.init)
    }

    func validated() throws -> [IrxLocalPeerAuthorization] {
        guard version == 1 else { throw IrxLocalPeerAuthorizationStore.StoreError.unsupportedVersion }
        return try entries.map { try $0.validated() }
    }
}
