/// Versioned scoped device list; decoding is followed by explicit validation.
struct CmxLocalDeviceCredentialRecord: Codable {
    let version: Int
    let devices: [CmxLocalDeviceRecord]
}
