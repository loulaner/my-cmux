import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC
@testable import CmuxMobileTransport

@Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectRPCLoopbackTests {
    @Test func admittedNativeStreamCarriesRPCAndEvents() async throws {
        let store = try CmxLocalDeviceCredentialStore(storage: RPCDirectMemoryStorage(), storageScope: "rpc-loopback")
        try await store.load()
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in true }, isCurrent: { true })
        let completion = AsyncStream<Bool>.makeStream()
        defer { completion.continuation.finish() }
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do {
                let accepted = try await admission.accept(stream)
                var buffer = Data()
                var frames: [Data] = []
                while frames.isEmpty, let bytes = try await accepted.transport.receive() {
                    buffer.append(bytes)
                    frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
                }
                let payload = try #require(frames.first)
                let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                #expect(Set(request.keys) == ["id", "method", "params"])
                let id = try #require(request["id"] as? String)
                var response = try MobileSyncFrameCodec.encodeFrame(Data(#"{"kind":"event","topic":"workspace.updated","payload":{"fixture":true}}"#.utf8))
                response.append(try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject:
                    ["id": id, "ok": true, "result": ["fixture": true]])))
                try await accepted.transport.send(response)
                _ = try await accepted.transport.receive() // Wait for client disconnect, not an arbitrary delay.
                completion.continuation.yield(true)
            } catch { Issue.record(error); completion.continuation.yield(false) }
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("Listener unavailable"); return }
        let connector = CmxLocalDirectConnector(makeAuthority: { RPCLoopbackRouteAuthority() }, permitsLoopbackForTesting: true)
        let transport = try await connector.connect(host: host, port: port)
        let accepted = try await CmxLocalDirectAdmission.pair(displayName: "Synthetic tablet", transport: transport)
        let client = MobileLocalDirectRPCClient(admittedTransport: accepted.transport)
        let events = await client.subscribe(to: ["workspace.updated"])
        let data = try await client.sendRequest(Data(#"{"method":"workspace.list","params":{}}"#.utf8))
        #expect(try JSONSerialization.jsonObject(with: data) as? [String: Bool] == ["fixture": true])
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next()?.topic == "workspace.updated")
        await client.disconnect()
        var finished = completion.stream.makeAsyncIterator()
        #expect(await finished.next() == true)
        await listener.stop()
    }
}
