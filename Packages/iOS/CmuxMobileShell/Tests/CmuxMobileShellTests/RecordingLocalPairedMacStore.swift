import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
@testable import CmuxMobileShell

actor LocalDeleteRecorder {
    private(set) var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

struct RecordingLocalPairedMacStore: MobilePairedMacStoring {
    let inner: any MobilePairedMacStoring
    let deletes = LocalDeleteRecorder()
    let routeWrites = LocalDeleteRecorder()
    func authorizeUserTailscaleRoutes(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?, routes: [CmxAttachRoute]) async throws {
        try await inner.authorizeUserTailscaleRoutes(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID, routes: routes)
    }
    func removeExactScope(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        await deletes.record("exact")
        try await inner.removeExactScope(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }
    func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.upsert(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertIfNewer(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, customName: String?, customColor: String?, customIcon: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertIfNewer(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, customName: customName, customColor: customColor, customIcon: customIcon, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertRoutesIfAuthorized(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], condition: MobilePairedMacRouteWriteCondition, markActive: Bool?, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        let wrote = try await inner.upsertRoutesIfAuthorized(macDeviceID: macDeviceID, displayName: displayName, routes: routes, condition: condition, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
        if wrote { await routeWrites.record(macDeviceID) }
        return wrote
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func loadAllInstances(macDeviceID: String, stackUserID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(macDeviceID: macDeviceID, stackUserID: stackUserID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(macDeviceID: String, customName: String?, customColor: String?, customIcon: String?, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.setCustomization(macDeviceID: macDeviceID, customName: customName, customColor: customColor, customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        await deletes.record("remove")
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func remove(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        await deletes.record("remove")
        try await inner.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeAll() async throws {
        await deletes.record("removeAll")
        try await inner.removeAll()
    }
}
