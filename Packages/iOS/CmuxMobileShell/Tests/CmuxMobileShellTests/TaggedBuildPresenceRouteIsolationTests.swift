import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileShell

/// Retained local/registry authority contracts, not retired push delivery tests.
@MainActor
@Suite struct TaggedBuildLocalRouteIsolationTests {
    @Test func tagBRestartCannotRewriteTagARoutesOnTheSameMac() async throws {
        let original = try route("original", 50000)
        let a = try route("a", 51001)
        let b = try route("b", 51002)
        let restartedB = try route("b-restart", 52002)
        let restartedA = try route("a-restart", 52001)
        let (local, directory) = try await localStore(rows: [row("mac", "feature-a", original)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = LocalRegistryRouteFixture()
        let shell = MobileShellComposite(isSignedIn: true, pairedMacStore: local, deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"), teamIDProvider: { "team-a" })
        for (routesA, routesB, expectedWrites) in [(a, b, 1), (a, restartedB, 1), (restartedA, restartedB, 2)] {
            await registry.setDevices([device("mac", [("feature-a", [routesA]), ("feature-b", [routesB])])])
            let captured = try #require(await local.activeMac(stackUserID: "user-1", teamID: "team-a"))
            shell.refreshRoutesFromRegistry(for: captured,
                scope: MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0))
            await shell.registryRouteRefreshTask?.value
            let stored = try #require(await local.activeMac(stackUserID: "user-1", teamID: "team-a"))
            #expect(stored.instanceTag == "feature-a")
            #expect(stored.routes == [routesA])
            #expect(await local.routeWrites.calls.count == expectedWrites)
        }
    }

    @Test func unscopedBuildUsesOnlyTheSoleRouteAdvertisingInstance() throws {
        let a = try route("a", 51001)
        let b = try route("b", 51002)
        let ambiguous = DeviceRegistryRouteIndex(devices: [device("mac", [("feature-a", [a]), ("feature-b", [b])])])
        #expect(ambiguous.resolve(macDeviceID: "mac", instanceTag: nil) == .ambiguous)
        let sole = DeviceRegistryRouteIndex(devices: [device("mac", [("feature-a", []), ("feature-b", [b])])])
        #expect(sole.resolve(macDeviceID: "mac", instanceTag: nil) == .unique([b]))
    }

    @Test func officialBuildUsesOnlyDefaultTaggedRegistryRoutes() throws {
        let stable = try route("stable", 51001)
        let other = try route("other", 51002)
        let index = DeviceRegistryRouteIndex(devices: [device("mac", [("default", [stable]), ("feature-b", [other])])])
        #expect(index.resolve(macDeviceID: "mac", instanceTag: "default") == .unique([stable]))
    }

    @Test func emptyRegistryRoutesDoNotSelectPersistedRouteErasure() throws {
        let original = try route("original", 50000)
        let index = DeviceRegistryRouteIndex(devices: [device("mac", [("feature-a", [])])])
        #expect(index.resolve(macDeviceID: "mac", instanceTag: "feature-a") == .missing)
        #expect(DeviceRegistryService.selectReconnectRoutes(local: [original], registry: []) == nil)
    }

    @Test func ambiguousLegacyRegistryCannotSelectEitherTag() throws {
        let a = try route("a", 51001)
        let b = try route("b", 51002)
        let index = DeviceRegistryRouteIndex(devices: [device("mac", [("feature-a", [a]), ("feature-b", [b])])])
        #expect(index.resolve(macDeviceID: "mac", instanceTag: nil) == .ambiguous)
    }

    @Test func twoPairedMacsUseTheirOwnAuthenticatedTags() async throws {
        let original = try route("original", 50000)
        let a = try route("a", 51001)
        let b = try route("b", 51002)
        let noiseA = try route("noise-a", 52001)
        let noiseB = try route("noise-b", 52002)
        let (local, directory) = try await localStore(rows: [
            row("mac-a", "feature-a", original), row("mac-b", "default", original),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = LocalRegistryRouteFixture()
        await registry.setDevices([
            device("mac-a", [("feature-a", [a]), ("default", [noiseA])]),
            device("mac-b", [("default", [b]), ("feature-a", [noiseB])]),
        ])
        let shell = MobileShellComposite(isSignedIn: true, pairedMacStore: local, deviceRegistry: registry,
            identityProvider: StaticIdentityProvider(userID: "user-1"), teamIDProvider: { "team-a" })
        for id in ["mac-a", "mac-b"] {
            try await local.setActive(macDeviceID: id, stackUserID: "user-1", teamID: "team-a")
            let captured = try #require(await local.activeMac(stackUserID: "user-1", teamID: "team-a"))
            shell.refreshRoutesFromRegistry(for: captured,
                scope: MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0))
            await shell.registryRouteRefreshTask?.value
        }
        let stored = try await local.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(stored.first { $0.macDeviceID == "mac-a" }?.routes == [a])
        #expect(stored.first { $0.macDeviceID == "mac-a" }?.instanceTag == "feature-a")
        #expect(stored.first { $0.macDeviceID == "mac-b" }?.routes == [b])
        #expect(stored.first { $0.macDeviceID == "mac-b" }?.instanceTag == "default")
    }

    @Test func localConditionalWriteUsesRowAddedAfterDisplayCacheLoaded() async throws {
        let original = try route("original", 50000)
        let updated = try route("updated", 51000)
        let pairedStore = DelayedTeamPairedMacStore(recordsByTeam: ["team-a": []], blockedTeams: [])
        let shell = MobileShellComposite(isSignedIn: true, pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"), teamIDProvider: { "team-a" })
        await shell.loadPairedMacs()
        try await pairedStore.upsert(macDeviceID: "mac-b", displayName: "Studio B", routes: [original],
            instanceTag: "feature-b", markActive: false, stackUserID: "user-1", teamID: "team-a", now: Date())
        #expect(shell.pairedMacs.isEmpty)
        let wrote = try await pairedStore.upsertRoutesIfAuthorized(macDeviceID: "mac-b", displayName: nil,
            routes: [updated], condition: .matchingInstanceTag("feature-b"), markActive: nil,
            stackUserID: "user-1", teamID: "team-a", now: Date())
        #expect(wrote)
        let rows = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.first?.routes == [updated])
        #expect(rows.first?.instanceTag == "feature-b")
    }

    private func localStore(rows: [MobilePairedMac]) async throws -> (RecordingLocalPairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = RecordingLocalPairedMacStore(inner: try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired.sqlite3")))
        for row in rows {
            try await store.upsert(macDeviceID: row.macDeviceID, displayName: row.displayName, routes: row.routes,
                instanceTag: row.instanceTag, markActive: row.isActive, stackUserID: row.stackUserID,
                teamID: row.teamID, now: row.lastSeenAt)
        }
        return (store, directory)
    }

    private func row(_ id: String, _ tag: String, _ route: CmxAttachRoute) -> MobilePairedMac {
        MobilePairedMac(macDeviceID: id, displayName: "Studio", routes: [route],
            createdAt: .distantPast, lastSeenAt: .distantPast, isActive: true,
            stackUserID: "user-1", teamID: "team-a", instanceTag: tag)
    }

    private func route(_ id: String, _ port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: id, kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: port))
    }

    private func device(_ id: String, _ entries: [(String, [CmxAttachRoute])]) -> RegistryDevice {
        RegistryDevice(deviceId: id, platform: "mac", displayName: "Studio", lastSeenAt: .distantPast,
            instances: entries.map { RegistryAppInstance(tag: $0.0, routes: $0.1, lastSeenAt: .distantPast) })
    }
}

private actor LocalRegistryRouteFixture: DeviceRegistryRefreshing {
    private var devices: [RegistryDevice] = []
    func setDevices(_ devices: [RegistryDevice]) { self.devices = devices }
    func listDevices() async -> DeviceRegistryListOutcome { .ok(devices) }
    func freshRoutes(forMacDeviceID id: String, instanceTag: String?) async -> [CmxAttachRoute]? {
        switch DeviceRegistryRouteIndex(devices: devices).resolve(macDeviceID: id, instanceTag: instanceTag) {
        case .unique(let routes): return routes
        case .missing, .ambiguous: return nil
        }
    }
}
