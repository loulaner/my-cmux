public import Foundation
import CmuxMobileTransport

/// The only remembered Mac and its device capability. Never log or sync this value.
public struct MobileLocalDirectClientRecord: Codable, Sendable, Equatable {
    /// Malformed or incomplete records are never usable capabilities.
    public enum ValidationError: Error { case invalidRecord }
    /// Persisted schema version.
    public let version: Int
    /// Canonical VPN peer IPv4.
    public let host: String
    /// Exact Mac TCP port.
    public let port: Int
    /// Stable identity returned by the authenticated Mac.
    public let hostID: String
    /// Device capability identifier issued during approval.
    public let deviceID: String
    /// Secret capability bytes; only private protected file storage may persist them.
    public let token: Data

    /// Validates a complete, already approved record; drafts must not be persisted.
    public init(host: String, port: Int, hostID: String, deviceID: String, token: Data) throws {
        _ = try CmxLocalTCPListenerConfiguration(address: host, port: port)
        guard UUID(uuidString: hostID) != nil, let device = UUID(uuidString: deviceID),
              device.uuidString.lowercased() == deviceID, token.count == 32 else { throw ValidationError.invalidRecord }
        version = 1
        self.host = host; self.port = port; self.hostID = hostID; self.deviceID = deviceID; self.token = token
    }

    private enum CodingKeys: String, CodingKey { case version, host, port, hostID, deviceID, token }
    /// Decodes and validates all required fields, including the schema version.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw ValidationError.invalidRecord }
        try self.init(host: values.decode(String.self, forKey: .host), port: values.decode(Int.self, forKey: .port),
            hostID: values.decode(String.self, forKey: .hostID), deviceID: values.decode(String.self, forKey: .deviceID),
            token: values.decode(Data.self, forKey: .token))
    }
}
