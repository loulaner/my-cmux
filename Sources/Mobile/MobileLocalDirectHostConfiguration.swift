import CmuxMobileTransport
import Foundation

/// Version-one host identity and opt-in binding, independent of account identity.
struct MobileLocalDirectHostConfiguration: Codable, Equatable, Sendable {
    let version: Int
    let hostID: String
    var enabled: Bool
    var address: String?
    var port: Int

    enum CodingKeys: String, CodingKey { case version, hostID, enabled, address, port }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(hostID, forKey: .hostID)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
    }

    static func initial() -> Self {
        Self(version: 1, hostID: UUID().uuidString.lowercased(), enabled: false, address: nil, port: 49443)
    }
    func validate() throws {
        guard version == 1, UUID(uuidString: hostID)?.uuidString.lowercased() == hostID,
              (1...65535).contains(port), !enabled || address != nil else {
            throw MobileLocalDirectConfigurationStore.Failure.invalidConfiguration
        }
        if let address { _ = try CmxLocalTCPListenerConfiguration(address: address, port: port) }
    }
}
