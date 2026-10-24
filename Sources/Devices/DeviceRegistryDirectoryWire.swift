import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation

/// Pure compatibility DTOs and decoding for legacy device registry data.
/// This type performs no directory requests or authentication.
struct DeviceRegistryDirectoryWire {
    struct Instance: Equatable, Sendable {
        let tag: String
        let routes: [CmxAttachRoute]
        let lastSeenAt: Date?
    }

    struct Device: Equatable, Sendable {
        let deviceID: String
        let platform: String
        let displayName: String?
        /// `labels.manual == true`: a remote the person added by hand with
        /// `cmux remotes add`, not a Mac running cmux.
        let isManual: Bool
        let lastSeenAt: Date?
        let instances: [Instance]
    }

    /// Decode the list response. Routes decode per entry so one unknown route
    /// kind never drops a device; timestamps parse leniently (ISO8601 with or
    /// without fractional seconds). Pure for tests.
    static func parse(_ data: Data) -> [Device]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDevices = object["devices"] as? [[String: Any]] else {
            return nil
        }
        return rawDevices.compactMap { raw -> Device? in
            guard let deviceID = (raw["deviceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !deviceID.isEmpty else { return nil }
            let labels = raw["labels"] as? [String: Any]
            let instances = ((raw["instances"] as? [[String: Any]]) ?? []).map { instance -> Instance in
                let tag = (instance["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Instance(
                    tag: tag.isEmpty ? SurfaceDeviceInstanceID.defaultTag : tag,
                    routes: parseRoutes(instance["routes"]),
                    lastSeenAt: parseTimestamp(instance["lastSeenAt"] as? String)
                )
            }
            return Device(
                deviceID: deviceID,
                platform: ((raw["platform"] as? String)?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "mac",
                displayName: (raw["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isManual: (labels?["manual"] as? Bool) ?? false,
                lastSeenAt: parseTimestamp(raw["lastSeenAt"] as? String),
                instances: instances
            )
        }
    }

    static func parseRoutes(_ raw: Any?) -> [CmxAttachRoute] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(CmxAttachRoute.self, from: data)
        }
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
