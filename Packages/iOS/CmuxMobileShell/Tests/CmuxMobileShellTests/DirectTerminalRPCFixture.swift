import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing

/// Synthetic screen-protocol RPC peer with independently controllable replay completion.
actor DirectTerminalRPCFixture: MobileSyncing {
    static let workspace = "00000000-0000-0000-0000-000000000011"
    static let surface = "00000000-0000-0000-0000-000000000012"
    private var events: AsyncStream<MobileEventEnvelope>.Continuation?
    private var streamID: String?
    private var revision: UInt64 = 0
    private var holdReplay = false
    private var replayBarrier: CheckedContinuation<Void, Never>?
    private var holdViewport = false
    private var viewportBarrier: CheckedContinuation<Void, Never>?
    private var holdInput = false
    private var inputBarrier: CheckedContinuation<Void, Never>?
    let calls = AsyncStream<String>.makeStream()
    private(set) var requests: [Data] = []
    private(set) var replays = 0
    private(set) var inputs: [String] = []
    private(set) var deliveries: [MobileTerminalInputDelivery] = []
    func configure(holdReplay: Bool = false, holdInput: Bool = false, holdViewport: Bool = false) { self.holdReplay = holdReplay; self.holdInput = holdInput; self.holdViewport = holdViewport }
    func releaseReplay() { holdReplay = false; replayBarrier?.resume(); replayBarrier = nil }
    func releaseViewport() { holdViewport = false; viewportBarrier?.resume(); viewportBarrier = nil }
    func releaseInput() { holdInput = false; inputBarrier?.resume(); inputBarrier = nil }
    func disconnect() { events?.finish(); releaseReplay(); releaseInput(); releaseViewport() }
    func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
        let channel = AsyncStream<MobileEventEnvelope>.makeStream(); events = channel.continuation; return channel.stream
    }
    static func frame(revision: UInt64, base: UInt64? = nil, text: String = "中") throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(surfaceID: surface, stateSeq: revision, renderEpoch: "fixture-epoch", renderRevision: revision,
            columns: 20, rows: 5, full: base == nil, styles: [], rowSpans: [.init(row: 0, column: 0, styleID: 0, text: text)],
            activeScreen: .primary, anchor: .screen, historyRows: 4, deltaBaseHistoryRows: base == nil ? nil : 4, deltaBaseRenderRevision: base)
    }
    func emit(_ frame: MobileTerminalRenderGridFrame) throws {
        revision = max(revision, frame.renderRevision)
        events?.yield(.init(topic: "terminal.render_grid", payloadJSON: try JSONEncoder().encode(frame), streamID: streamID))
    }
    func detach() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["surface_id": Self.surface])
        events?.yield(.init(topic: "mobile.terminal.detached", payloadJSON: payload, streamID: streamID))
    }
    func sendRequest(_ data: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
        requests.append(data)
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try #require(request["method"] as? String)
        let params = try #require(request["params"] as? [String: Any])
        calls.continuation.yield(method)
        if method == "mobile.events.subscribe" {
            streamID = params["stream_id"] as? String
            #expect(params["render_grid_anchor"] as? String == "screen")
            #expect(params["event_transport"] as? String == "control_v1")
            return Data("{}".utf8)
        }
        if method == "mobile.events.unsubscribe" { return Data("{}".utf8) }
        #expect(params["workspace_id"] as? String == Self.workspace)
        #expect(params["surface_id"] as? String == Self.surface)
        if method == "mobile.terminal.viewport" {
            if holdViewport { await withCheckedContinuation { viewportBarrier = $0 } }
            return Data(#"{"columns":20,"rows":5,"render_epoch":"fixture-epoch","render_revision_floor":0}"#.utf8) }
        if method == "mobile.terminal.replay" || method == "mobile.terminal.reattach" {
            replays += 1; revision += 1
            #expect(params["anchor"] as? String == "screen")
            let response = try JSONSerialization.data(withJSONObject: ["surface_id": Self.surface,
                "workspace_id": Self.workspace, "render_grid": try Self.frame(revision: revision).jsonObject()])
            if holdReplay { await withCheckedContinuation { replayBarrier = $0 } }
            return response
        }
        if method == "mobile.terminal.input" {
            let surface = try #require(UUID(uuidString: Self.surface))
            let identity = try #require(MobileTerminalInputDelivery.fromRPC(parameters: params, surfaceID: surface))
            deliveries.append(identity); inputs.append(try #require(params["text"] as? String))
            if holdInput { await withCheckedContinuation { inputBarrier = $0 } }
            return try JSONSerialization.data(withJSONObject: MobileTerminalInputAcknowledgement(status: .applied,
                streamID: identity.streamID, sequence: identity.sequence).rpcPayload)
        }
        return Data("{}".utf8)
    }
}
