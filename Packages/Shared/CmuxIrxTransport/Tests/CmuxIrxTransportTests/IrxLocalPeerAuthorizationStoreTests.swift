import Foundation
import Testing
import CmuxIrohTransport
@testable import CmuxIrxTransport

@Suite("Local authorization persistence")
struct IrxLocalPeerAuthorizationStoreTests {
    private let key = String(repeating: "ab", count: 32)

    private func peer() throws -> IrxLocalPeerAuthorization {
        try IrxLocalPeerAuthorization(endpointIDHex: key.uppercased(), bindingID: " binding ",
            deviceID: "device", tag: "tag", identityGeneration: 2, revoked: false)
    }

    @Test func roundTripScopesAndRevoke() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let current = IrxLocalPeerAuthorizationCurrent()
        let store = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "one", current: current)
        try await store.load()
        #expect(current.current.isEmpty)
        try await store.replace([peer()])
        let restarted = IrxLocalPeerAuthorizationCurrent()
        let reader = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "one", current: restarted)
        try await reader.load()
        #expect(restarted.current == current.current)
        let isolated = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "two", current: restarted)
        try await isolated.load()
        #expect(restarted.current.isEmpty)
        #expect(try await store.revoke(endpointIDHex: key.uppercased()))
        try await reader.load()
        #expect(restarted.current[key]?.revoked == true)
        #expect(restarted.current[key]?.bindingID == "binding")
        #expect(!(try await store.revoke(endpointIDHex: String(repeating: "cd", count: 32))))
        try await store.clear()
        try await reader.load()
        #expect(restarted.current.isEmpty)
        #expect(await secure.accessibilities == [.afterFirstUnlockThisDeviceOnly, .afterFirstUnlockThisDeviceOnly])
    }

    @Test func failuresDoNotPublishAndClearFailsClosed() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let current = IrxLocalPeerAuthorizationCurrent()
        let store = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "test", current: current)
        let original = try peer()
        try await store.replace([original])
        let saved = await secure.records
        await #expect(throws: IrxLocalPeerAuthorizationCurrent.ReplacementError.duplicateEndpointID) {
            try await store.replace([original, original])
        }
        #expect(await secure.records == saved)
        await secure.setFailure(.write)
        await #expect(throws: LocalAuthorizationCredentialFake.Failure.write) { try await store.replace([]) }
        #expect(current.current == [key: original])
        await secure.setFailure(.delete)
        await #expect(throws: LocalAuthorizationCredentialFake.Failure.delete) { try await store.clear() }
        #expect(current.current.isEmpty)
        #expect(await secure.records == saved)
        await secure.setFailure(nil)
        try await store.load()
        #expect(current.current == [key: original]) // Failed deletion is not durable revocation.
        await secure.setFailure(.read)
        await #expect(throws: LocalAuthorizationCredentialFake.Failure.read) { try await store.load() }
        #expect(current.current.isEmpty)
    }

    @Test(arguments: ["broken", "{\"version\":2,\"entries\":[]}",
        "{\"version\":1,\"entries\":[{}]}"])
    func invalidRecordsFailClosed(json: String) async throws {
        let secure = LocalAuthorizationCredentialFake()
        let current = IrxLocalPeerAuthorizationCurrent()
        let store = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "test", current: current)
        try await store.replace([peer()])
        await secure.corrupt(Data(json.utf8))
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(current.current.isEmpty)
        #expect(await secure.records.values.first == Data(json.utf8))
    }

    @Test func duplicateAndInvalidFieldsFailClosed() async throws {
        for invalidField in [false, true] {
            let secure = LocalAuthorizationCredentialFake()
            let current = IrxLocalPeerAuthorizationCurrent()
            let store = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "test", current: current)
            try await store.replace([peer()])
            let entry: [String: Any] = ["endpointIDHex": key, "bindingID": invalidField ? " " : "binding",
                "deviceID": "device", "tag": "tag", "identityGeneration": 1, "revoked": false]
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": invalidField ? [entry] : [entry, entry]])
            await secure.corrupt(data)
            await #expect(throws: (any Error).self) { try await store.load() }
            #expect(current.current.isEmpty)
        }
    }

    @Test func emptyScopeRejected() {
        #expect(throws: IrxLocalPeerAuthorizationStore.StoreError.emptyScope) {
            try IrxLocalPeerAuthorizationStore(secureStore: LocalAuthorizationCredentialFake(),
                storageScope: " \n", current: IrxLocalPeerAuthorizationCurrent())
        }
    }

    @Test func blockedLoadThenReplaceAndBlockedWriteThenRevoke() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let current = IrxLocalPeerAuthorizationCurrent()
        let store = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "race", current: current)
        await secure.blockNext(.read)
        let load = Task { try await store.load() }
        await secure.waitUntilBlocked()
        let replace = Task { try await store.replace([peer()]) }
        await secure.release()
        try await load.value
        try await replace.value
        #expect(current.current[key]?.revoked == false)
        await secure.blockNext(.write)
        let write = Task { try await store.replace([peer()]) }
        await secure.waitUntilBlocked()
        let revoke = Task { try await store.revoke(endpointIDHex: key) }
        write.cancel() // An already started transaction must finish.
        await secure.release()
        try await write.value
        #expect(try await revoke.value)
        try await store.load()
        #expect(current.current[key]?.revoked == true)
    }
}
