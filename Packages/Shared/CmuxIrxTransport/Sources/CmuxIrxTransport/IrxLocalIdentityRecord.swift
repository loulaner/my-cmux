import Foundation
import CryptoKit

/// Private persistence DTO; decoding alone never establishes a usable identity.
struct IrxLocalIdentityRecord: Codable {
    let version: Int
    let seed: Data
    let deviceID: String
    let appInstanceID: String

    init(_ identity: IrxIdentity) {
        version = 1
        seed = identity.privateKeyData
        deviceID = identity.deviceID
        appInstanceID = identity.appInstanceID
    }

    func validatedIdentity() throws -> IrxIdentity {
        guard version == 1 else { throw IrxLocalIdentityStore.StoreError.unsupportedVersion }
        guard seed.count == 32,
              (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)) != nil,
              !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !appInstanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IrxLocalIdentityStore.StoreError.invalidRecord
        }
        return IrxIdentity(privateKeyData: seed, deviceID: deviceID, appInstanceID: appInstanceID)
    }
}
