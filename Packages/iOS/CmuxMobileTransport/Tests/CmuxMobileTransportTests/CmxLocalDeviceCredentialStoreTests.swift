import Foundation
import Testing
@testable import CmuxMobileTransport

struct CmxLocalDeviceCredentialStoreTests {
    @Test func issueReloadAuthenticateAndRevoke() async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "scope")
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.invalidCredential) {
            try await store.authenticate(deviceID: "unknown", token: Data(repeating: 0, count: 32))
        }
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.notLoaded) {
            try await store.issueDevice(displayName: "Device")
        }
        try await store.load()
        let issued = try await store.issueDevice(displayName: " Device ")
        #expect(issued.token.count == 32)
        #expect(issued.device.displayName == "Device")
        let bytes = try #require(await memory.records.values.first)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(issued.token.base64EncodedString()))
        #expect(!text.contains("token"))
        let restart = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "scope")
        try await restart.load()
        #expect(try await restart.authenticate(deviceID: issued.device.deviceID, token: issued.token) == issued.device)
        for (id, token) in [("unknown", issued.token), (issued.device.deviceID, Data(repeating: 0, count: 32)),
                            (issued.device.deviceID, Data())] {
            await #expect(throws: CmxLocalDeviceCredentialStore.Failure.invalidCredential) {
                try await restart.authenticate(deviceID: id, token: token)
            }
        }
        #expect(try await restart.revoke(deviceID: issued.device.deviceID))
        #expect(!(try await restart.revoke(deviceID: issued.device.deviceID)))
        #expect(await memory.writes == 2)
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.invalidCredential) {
            try await restart.authenticate(deviceID: issued.device.deviceID, token: issued.token)
        }
    }

    @Test func concurrentUpdatesAndLimits() async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "scope")
        try await store.load()
        let old = try await store.issueDevice(displayName: "old")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await store.issueDevice(displayName: "new") } }
            group.addTask { _ = try await store.revoke(deviceID: old.device.deviceID) }
            try await group.waitForAll()
        }
        #expect(await store.devices().count == 20)
        #expect(await store.devices().allSatisfy { $0.deviceID != old.device.deviceID })
        for _ in 0..<12 { _ = try await store.issueDevice(displayName: "more") }
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.deviceLimit) {
            try await store.issueDevice(displayName: "excess")
        }
        for name in ["", " \t", "line\nbreak", String(repeating: "a", count: 65)] {
            await #expect(throws: CmxLocalDeviceCredentialStore.Failure.invalidDisplayName) {
                try await store.issueDevice(displayName: name)
            }
        }
    }

    @Test func failedWritesNeverPublishAndLoadFailureClears() async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "scope")
        try await store.load()
        let issued = try await store.issueDevice(displayName: "Device")
        let stored = await memory.records
        await memory.failures(write: true)
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.storageFailure) {
            try await store.issueDevice(displayName: "Failed")
        }
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.storageFailure) {
            try await store.revoke(deviceID: issued.device.deviceID)
        }
        #expect(await memory.records == stored)
        #expect(try await store.authenticate(deviceID: issued.device.deviceID, token: issued.token) == issued.device)
        await memory.failures(read: true)
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.storageFailure) { try await store.load() }
        #expect(await store.devices().isEmpty)
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.invalidCredential) {
            try await store.authenticate(deviceID: issued.device.deviceID, token: issued.token)
        }
    }

    @Test(arguments: ["json", "version", "digest", "id", "name", "duplicate", "limit"])
    func invalidRecordsFailClosed(kind: String) async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "scope")
        try await store.load()
        _ = try await store.issueDevice(displayName: "Device")
        let entry: [String: Any] = ["deviceID": kind == "id" ? "bad" : UUID().uuidString.lowercased(),
            "displayName": kind == "name" ? "\n" : "Device",
            "digest": Data(repeating: 0, count: kind == "digest" ? 31 : 32).base64EncodedString()]
        let entries = Array(repeating: entry, count: kind == "limit" ? 33 : kind == "duplicate" ? 2 : 1)
        let data = kind == "json" ? Data("bad".utf8) : try JSONSerialization.data(withJSONObject:
            ["version": kind == "version" ? 2 : 1, "devices": entries])
        await memory.corrupt(data)
        await #expect(throws: CmxLocalDeviceCredentialStore.Failure.invalidRecord) { try await store.load() }
        #expect(await store.devices().isEmpty)
        #expect(await memory.records.values.first == data)
        #expect(await memory.writes == 1)
    }

    @Test func scopesRemainIndependent() async throws {
        let memory = LocalDeviceMemoryStorage()
        for scope in ["a", " a"] {
            let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: scope)
            try await store.load()
            #expect(await store.devices().isEmpty)
            _ = try await store.issueDevice(displayName: "Device")
        }
        #expect(await Set(memory.records.keys) == Set(["local-direct-devices-v1:61", "local-direct-devices-v1:2061"]))
    }
}
