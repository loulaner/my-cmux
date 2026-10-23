import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell
@testable import CmuxMobileTransport

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectTerminalLoopbackTests {
    @Test func sharedNativeClientCarriesSubscriptionReplayAndInput() async throws {
        let credentials = try CmxLocalDeviceCredentialStore(storage: ShellDirectMemoryStorage(), storageScope: "terminal-loopback")
        try await credentials.load()
        let admission = CmxLocalDirectAdmission(store: credentials, approval: { _ in true }, isCurrent: { true })
        let peer = DirectTerminalRPCFixture()
        let sends = AsyncStream<String>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do {
                let accepted = try await admission.accept(stream)
                var buffer = Data()
                while let bytes = try await accepted.transport.receive() {
                    buffer.append(bytes)
                    for data in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
                        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        let method = try #require(object["method"] as? String)
                        let id = try #require(object["id"] as? String)
                        let resultData: Data
                        if method == "workspace.list" { resultData = Data(#"{"workspaces":[]}"#.utf8) }
                        else { resultData = try await peer.sendRequest(data, timeoutNanoseconds: nil) }
                        let result = try JSONSerialization.jsonObject(with: resultData)
                        try await accepted.transport.send(MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": result])))
                        sends.continuation.yield(method)
                    }
                }
                completed.continuation.yield(true)
            } catch { Issue.record(error); completed.continuation.yield(false) }
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("Listener unavailable"); return }
        let stream = try await CmxLocalDirectConnector(makeAuthority: { ShellLoopbackRouteAuthority() }, permitsLoopbackForTesting: true)
            .connect(host: host, port: port)
        let accepted = try await CmxLocalDirectAdmission.pair(displayName: "Synthetic tablet", transport: stream)
        let client = MobileLocalDirectRPCClient(admittedTransport: accepted.transport)
        _ = try await client.sendRequest(Data(#"{"method":"workspace.list","params":{}}"#.utf8))
        var generation: UInt64 = 0
        let session = MobileLocalDirectTerminalSession(rpc: client, workspaceID: DirectTerminalRPCFixture.workspace,
            surfaceID: DirectTerminalRPCFixture.surface, clientID: accepted.deviceID, connectionGeneration: 1,
            capabilities: ["terminal.render_grid.v1", "terminal.render_grid.screen_anchor.v1", MobileTerminalInputDelivery.capability],
            nextViewportGeneration: { generation += 1; return generation })
        let sink = DirectTerminalRenderSink()
        session.resize(columns: 20, rows: 5, reportID: 1)
        session.mount(apply: sink.apply, confirmViewport: { _, _, _ in })
        while session.state != .ready {
            if session.state == .failed || session.state == .incompatible { Issue.record("Terminal unavailable"); break }
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = session.state } onChange: { continuation.resume() }
            }
        }
        session.input(Data("中\u{3}\r".utf8))
        var sent = sends.stream.makeAsyncIterator()
        while await sent.next() != "mobile.terminal.input" {}
        #expect(await peer.inputs == ["中\u{3}\r"])
        #expect(sink.frames.count == 1)
        session.invalidate()
        while await sent.next() != "mobile.events.unsubscribe" {} // Renderer teardown is not an explicit disconnect.
        await client.disconnect()
        var done = completed.stream.makeAsyncIterator()
        #expect(await done.next() == true)
        let requests = try await peer.requests.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let viewports = requests.filter { $0?["method"] as? String == "mobile.terminal.viewport" }
        #expect(viewports.count == 1) // Initial sizing only; no implicit clear on teardown.
        await listener.stop()
        sends.continuation.finish(); completed.continuation.finish()
    }
}
