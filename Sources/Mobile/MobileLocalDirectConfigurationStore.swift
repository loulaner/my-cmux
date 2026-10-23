import Foundation

/// Publishes a generated identity only after its first private-file write succeeds.
actor MobileLocalDirectConfigurationStore {
    enum Failure: Error { case invalidConfiguration, unavailable }
    private let files: CmxLocalDeviceFileStorage
    private var loading: Task<MobileLocalDirectHostConfiguration, any Error>?
    init(files: CmxLocalDeviceFileStorage) { self.files = files }

    func load() async throws -> MobileLocalDirectHostConfiguration {
        if let loading { return try await loading.value }
        let task = Task { [files] in
            do {
                if let data = try await files.readConfiguration() {
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          Set(object.keys) == Set(["version", "hostID", "enabled", "address", "port"]),
                          let value = try? JSONDecoder().decode(MobileLocalDirectHostConfiguration.self, from: data) else {
                        throw Failure.invalidConfiguration
                    }
                    try value.validate()
                    return value
                }
                let value = MobileLocalDirectHostConfiguration.initial()
                try await files.writeConfiguration(JSONEncoder().encode(value))
                return value
            } catch { throw Failure.unavailable }
        }
        loading = task
        do { return try await task.value } catch { loading = nil; throw Failure.unavailable }
    }
    func save(_ configuration: MobileLocalDirectHostConfiguration) async throws {
        try configuration.validate()
        let existing = try await load()
        guard existing.hostID == configuration.hostID else { throw Failure.invalidConfiguration }
        do { try await files.writeConfiguration(JSONEncoder().encode(configuration)) }
        catch { throw Failure.unavailable }
        loading = Task { configuration }
    }
}
