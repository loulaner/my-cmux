import CMUXMobileCore

import Foundation
import Observation
import Testing
@testable import CmuxMobileShell
@testable import CmuxMobileTransport
import CmuxMobileRPC

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectClientLoopbackTests {
    @Test func nativePairListPersistReloadAndAuthenticate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clientStore = MobileLocalDirectClientFileStore(baseURL: root.appendingPathComponent("local-direct"))
        let serverStore = try CmxLocalDeviceCredentialStore(storage: ShellDirectMemoryStorage(), storageScope: "shell-native-fixture")
        try await serverStore.load()
        let approvals = AsyncStream<Bool>.makeStream()
        let admission = CmxLocalDirectAdmission(store: serverStore, approval: { _ in
            approvals.continuation.yield(true); return true
        }, isCurrent: { true })
        let peer = MobileDirectClientFixture()
        let completed = AsyncStream<Bool>.makeStream()
        let drop = NativeAdmissionDropCounter()
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do {
                if await drop.shouldDrop() {
                    let (request, _) = try await CmxLocalDirectWire.read(from: stream)
                    #expect(try CmxLocalDirectWire.decode(request, response: false).operation == "authenticate")
                    await stream.close()
                    return
                }
                let accepted = try await admission.accept(stream)
                var buffer = Data()
                while let bytes = try await accepted.transport.receive() {
                    buffer.append(bytes)
                    for request in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
                        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
                        #expect(Set(object.keys) == ["id", "method", "params"])
                        let id = try #require(object["id"] as? String)
                        let responseData = try await peer.sendRequest(request, timeoutNanoseconds: nil)
                        let result = try JSONSerialization.jsonObject(with: responseData)
                        let frame = try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result]))
                        try await accepted.transport.send(frame)
                    }
                }
                completed.continuation.yield(true)
            } catch { Issue.record(error); completed.continuation.yield(false) }
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("Fixture listener unavailable"); return }
        let dial: @Sendable (String, Int) async throws -> any CmxByteTransport = { _, _ in
            // Test seam maps a synthetic persisted VPN address to this fixture's loopback proof.
            try await CmxLocalDirectConnector(makeAuthority: { ShellLoopbackRouteAuthority() }, permitsLoopbackForTesting: true)
                .connect(host: host, port: port)
        }
        let first = MobileLocalDirectClientController(store: clientStore, connect: dial)
        await first.setForeground(true)
        first.address = "100.70.1.2"
        await first.pair()
        await wait(first)
        #expect(first.workspaces.first?.terminals.map(\.id) == ["terminal-a"])
        let saved = try #require(await clientStore.load())
        await first.setForeground(false)
        var done = completed.stream.makeAsyncIterator()
        #expect(await done.next() == true)
        let second = MobileLocalDirectClientController(store: clientStore, connect: dial)
        await second.setForeground(true)
        await wait(second)
        #expect(try await clientStore.load() == saved)
        #expect(second.isRemembered)
        #expect(await drop.count == 3)
        await second.setForeground(false)
        #expect(await done.next() == true)
        approvals.continuation.finish()
        var approvalCount = 0
        for await _ in approvals.stream { approvalCount += 1 }
        #expect(approvalCount == 1)
        await listener.stop()
        completed.continuation.finish()
    }
    private func wait(_ controller: MobileLocalDirectClientController) async {
        while controller.state != .connected {
            if case .error = controller.state { Issue.record("Fixture did not connect"); return }
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = controller.state } onChange: { continuation.resume() }
            }
        }
    }
}
