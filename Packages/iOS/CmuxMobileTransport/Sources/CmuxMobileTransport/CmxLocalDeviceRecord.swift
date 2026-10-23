import Foundation

/// Private persisted entry containing only metadata and a SHA-256 digest.
struct CmxLocalDeviceRecord: Codable, Sendable {
    let deviceID: String
    let displayName: String
    let digest: Data

    var device: CmxLocalDevice { CmxLocalDevice(deviceID: deviceID, displayName: displayName) }
}
