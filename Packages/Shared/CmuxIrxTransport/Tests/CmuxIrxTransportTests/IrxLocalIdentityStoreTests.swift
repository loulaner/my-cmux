import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct IrxLocalIdentityStoreTests {
    @Test func persistsAndReloadsExactIdentity() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let store = try IrxLocalIdentityStore(secureStore: secure, storageScope: "host")
        #expect(await secure.records.isEmpty)
        let identity = try await store.loadOrCreate()
        #expect(identity.privateKeyData.count == 32)
        #expect(identity.publicKeyData.count == 32)
        #expect(UUID(uuidString: identity.deviceID) != nil)
        #expect(UUID(uuidString: identity.appInstanceID) != nil)
        #expect(identity.deviceID == identity.deviceID.lowercased())
        #expect(identity.appInstanceID == identity.appInstanceID.lowercased())
        #expect(identity.deviceID != identity.appInstanceID)
        let restarted = try IrxLocalIdentityStore(secureStore: secure, storageScope: "host")
        let reloaded = try await restarted.loadOrCreate()
        #expect(reloaded == identity)
        #expect(await secure.accessibilities == [.afterFirstUnlockThisDeviceOnly])
    }

    @Test func concurrentCallsCreateOnceEvenAcrossSuspension() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let store = try IrxLocalIdentityStore(secureStore: secure, storageScope: "concurrent")
        // A group exposes actor reentrancy through the fake's asynchronous read/write.
        let identities = try await withThrowingTaskGroup(of: IrxIdentity.self) { group in
            for _ in 0..<20 { group.addTask { try await store.loadOrCreate() } }
            var results: [IrxIdentity] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(identities.count == 20)
        #expect(identities.allSatisfy { $0 == identities.first })
        #expect(await secure.accessibilities.count == 1)
    }

    @Test func suspendedWriteAndCancelledCallerStillCommitOneIdentity() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let store = try IrxLocalIdentityStore(secureStore: secure, storageScope: "suspended")
        await secure.blockNext(.write)
        let first = Task { try await store.loadOrCreate() }
        await secure.waitUntilBlocked()
        #expect(await secure.records.isEmpty)
        let second = Task { try await store.loadOrCreate() }
        first.cancel()
        await secure.release()
        let committed = try await first.value
        #expect(try await second.value == committed)
        #expect(await secure.records.count == 1)
        #expect(await secure.accessibilities.count == 1)
    }

    @Test func failuresNeverReturnCachedOrUnpersistedIdentity() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let store = try IrxLocalIdentityStore(secureStore: secure, storageScope: "failures")
        await secure.setFailure(.write)
        await #expect(throws: LocalAuthorizationCredentialFake.Failure.write) { try await store.loadOrCreate() }
        #expect(await secure.records.isEmpty)
        await secure.setFailure(nil)
        let saved = try await store.loadOrCreate()
        let records = await secure.records
        await secure.setFailure(.read)
        await #expect(throws: LocalAuthorizationCredentialFake.Failure.read) { try await store.loadOrCreate() }
        #expect(await secure.records == records)
        await secure.setFailure(nil)
        #expect(try await store.loadOrCreate() == saved)
        #expect(await secure.accessibilities.count == 1)
    }

    @Test func scopesAreExactAndSeparateFromAuthorizations() async throws {
        let secure = LocalAuthorizationCredentialFake()
        let one = try IrxLocalIdentityStore(secureStore: secure, storageScope: "a")
        let two = try IrxLocalIdentityStore(secureStore: secure, storageScope: " a")
        let first = try await one.loadOrCreate()
        let second = try await two.loadOrCreate()
        #expect(first != second)
        let auth = try IrxLocalPeerAuthorizationStore(secureStore: secure, storageScope: "a",
            current: IrxLocalPeerAuthorizationCurrent())
        try await auth.replace([])
        #expect(await Set(secure.records.keys) == Set([
            "local-host-identity-v1:61", "local-host-identity-v1:2061", "local-peer-authorization-v1:61"]))
        #expect(try await one.loadOrCreate() == first)
        #expect(throws: IrxLocalIdentityStore.StoreError.emptyScope) {
            try IrxLocalIdentityStore(secureStore: secure, storageScope: " \n")
        }
    }

    @Test(arguments: ["json", "version", "shortSeed", "longSeed", "device", "instance"])
    func invalidRecordsAreNeverOverwritten(kind: String) async throws {
        let secure = LocalAuthorizationCredentialFake()
        let store = try IrxLocalIdentityStore(secureStore: secure, storageScope: "invalid")
        _ = try await store.loadOrCreate()
        let count = kind == "shortSeed" ? 31 : kind == "longSeed" ? 33 : 32
        let object: [String: Any] = ["version": kind == "version" ? 2 : 1,
            "seed": Data(repeating: 7, count: count).base64EncodedString(),
            "deviceID": kind == "device" ? " \t" : "device",
            "appInstanceID": kind == "instance" ? "\n" : "instance"]
        let data = kind == "json" ? Data("bad".utf8) : try JSONSerialization.data(withJSONObject: object)
        await secure.corrupt(data)
        await #expect(throws: IrxLocalIdentityStore.StoreError.self) { try await store.loadOrCreate() }
        #expect(await secure.records.values.first == data)
        #expect(await secure.accessibilities.count == 1)
    }
}
