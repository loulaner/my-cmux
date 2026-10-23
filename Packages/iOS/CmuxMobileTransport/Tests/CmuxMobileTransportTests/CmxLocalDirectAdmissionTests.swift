import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

struct CmxLocalDirectAdmissionTests {
    @Test func approvedPairPersistsAndPreservesRPC() async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "admission-test")
        try await store.load()
        let rpc = try MobileSyncFrameCodec.encodeFrame(Data("{\"id\":1,\"method\":\"mobile.host.status\"}".utf8))
        var frame = try CmxLocalDirectWire(operation: "pair", displayName: "Test tablet").framed()
        frame.append(rpc)
        let stream = LocalDirectScriptedTransport(chunks: [frame])
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in true }, isCurrent: { true })
        let accepted = try await admission.accept(stream)
        #expect(await memory.writes == 1)
        #expect(await accepted.isAuthorized())
        #expect(try await accepted.transport.receive() == rpc)
        #expect(await store.devices() == [accepted.peer])
    }
    @Test(arguments: ["deny", "stale", "write", "timeout", "invalidName"])
    func pairingFailureDoesNotPublish(_ kind: String) async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "admission-test")
        try await store.load()
        await memory.failures(write: kind == "write")
        let frame = try CmxLocalDirectWire(operation: "pair", displayName: kind == "invalidName" ? "bad\nname" : "Tablet").framed()
        let stream = LocalDirectScriptedTransport(chunks: [frame])
        let (never, finish) = AsyncStream<Bool>.makeStream()
        defer { finish.finish() }
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in
            if kind == "timeout" { for await value in never { return value }; return false }
            return kind != "deny"
        }, isCurrent: { kind != "stale" }, clock: ContinuousClock(),
        readTimeout: .seconds(10), approvalTimeout: kind == "timeout" ? .zero : .seconds(60))
        await #expect(throws: CmxLocalDirectAdmission.Failure.self) { try await admission.accept(stream) }
        #expect(await memory.writes == 0)
        #expect(await store.devices().isEmpty)
        #expect(await stream.closed)
        var response = try #require(await stream.sent.first)
        let decoded = try MobileSyncFrameCodec.decodeFrames(from: &response)
        #expect(try CmxLocalDirectWire.decode(#require(decoded.first), response: true).status == "denied")
    }

    @Test(arguments: ["correct", "wrongToken", "revoked", "version", "unknown", "extra", "oversize"])
    func authenticationAndStrictFirstFrame(_ kind: String) async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "admission-test")
        try await store.load()
        let issued = try await store.issueDevice(displayName: "Tablet")
        if kind == "revoked" { _ = try await store.revoke(deviceID: issued.device.deviceID) }
        var request: [String: Any] = ["version": kind == "version" ? 2 : 1,
            "operation": kind == "unknown" ? "other" : "authenticate", "deviceID": issued.device.deviceID,
            "token": (kind == "wrongToken" ? Data(repeating: 0, count: 32) : issued.token).base64EncodedString()]
        if kind == "extra" { request["extra"] = true }
        let frame = kind == "oversize" ? Data([0, 0, 16, 1]) : try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: request))
        let stream = LocalDirectScriptedTransport(chunks: frame.map { Data([$0]) })
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in Issue.record("Auth must not approve"); return false }, isCurrent: { true })
        if kind == "correct" {
            let accepted = try await admission.accept(stream)
            #expect(accepted.peer == issued.device)
            _ = try await store.revoke(deviceID: issued.device.deviceID)
            #expect(!(await accepted.isAuthorized()))
        } else {
            await #expect(throws: CmxLocalDirectAdmission.Failure.self) { try await admission.accept(stream) }
            #expect(await stream.closed)
        }
    }

    @Test func realLoopbackPairAndFollowingRPCFrame() async throws {
        let memory = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: memory, storageScope: "admission-loopback")
        try await store.load()
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in true }, isCurrent: { true })
        let request = try MobileSyncFrameCodec.encodeFrame(Data("{\"id\":1,\"method\":\"mobile.host.status\",\"params\":{}}".utf8))
        let response = try MobileSyncFrameCodec.encodeFrame(Data("{\"id\":1,\"ok\":true,\"result\":{}}".utf8))
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do {
                let accepted = try await admission.accept(stream)
                #expect(try await accepted.transport.receive() == request)
                try await accepted.transport.send(response)
            } catch { Issue.record(error) }
        }
        await listener.start()
        guard case let .listening(address, port) = await listener.state else { Issue.record("No loopback listener"); return }
        // Internal test-only loopback client; product callers must supply a route-proven stream.
        let raw = try CmxNetworkByteTransport(host: address, port: port)
        try await raw.connect()
        let client = try await CmxLocalDirectAdmission.pair(displayName: "Tablet", transport: raw)
        #expect(client.issuedToken?.count == 32)
        try await client.transport.send(request)
        #expect(try await client.transport.receive() == response)
        await client.transport.close()
        await listener.stop()
    }

    @Test func cancellationUnblocksDeadlineWithoutWaitingForApproval() async throws {
        let (started, signal) = AsyncStream<Bool>.makeStream()
        let (blocked, unblock) = AsyncStream<Bool>.makeStream()
        defer { signal.finish(); unblock.finish() }
        let task = Task {
            try await CmxLocalDirectDeadline<Bool>().run(timeout: .seconds(60), clock: ContinuousClock()) {
                signal.yield(true)
                for await value in blocked { return value }
                return false
            }
        }
        var iterator = started.makeAsyncIterator()
        #expect(await iterator.next() == true)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}
