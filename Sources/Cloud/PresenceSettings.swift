/// Shared service routing constants and the retired heartbeat preference key.
enum PresenceSettings {
    /// Historical heartbeat preference; no longer consumed or migrated.
    static let enabledKey = "presenceHeartbeatEnabled"
    /// Base URL of the presence service (the cmux-presence worker), e.g.
    /// "https://cmux-presence.<account>.workers.dev". Empty uses the Debug default.
    static let serviceURLKey = "presenceServiceURL"
    /// Env override for dev/tagged builds, mirroring CMUX_VM_API_BASE_URL.
    static let serviceURLEnvKey = "CMUX_PRESENCE_BASE_URL"
    /// The dev/staging worker (dev Stack project), the Debug-build default.
    /// See workers/presence/README.md.
    static let debugDefaultServiceURL = "https://cmux-presence-dev.debussy.workers.dev"

    /// The production presence worker, pinned for Release and production auth.
    /// See workers/presence/README.md.
    static let productionServiceURL = "https://presence.cmux.dev"

}
