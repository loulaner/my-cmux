import CmuxCloud
import Foundation

/// Resolves the shared service URL without starting a presence producer.
struct PresenceServiceEndpoint {
    /// Uses the current process routing settings for the remaining clients.
    func resolvedServiceURL() -> URL? {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return resolvedServiceURL(
            environment: ProcessInfo.processInfo.environment,
            defaults: .standard,
            isDebugBuild: isDebugBuild
        )
    }

    /// Preserves production pinning and Debug override precedence.
    func resolvedServiceURL(
        environment: [String: String],
        defaults: UserDefaults,
        isDebugBuild: Bool
    ) -> URL? {
        if !isDebugBuild
            || AuthEnvironment.resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: isDebugBuild
            ) == .production {
            return URL(string: PresenceSettings.productionServiceURL)
        }
        var raw = environment[PresenceSettings.serviceURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? defaults.string(forKey: PresenceSettings.serviceURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == nil || raw?.isEmpty == true {
            raw = PresenceSettings.debugDefaultServiceURL
        }
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
