#if DEBUG && canImport(UIKit)
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShell
import Foundation

/// In-memory screen-protocol peer for presentation tests only. No sockets, disk credentials or VPN exceptions.
actor LocalTerminalRendererRPCFixture: MobileSyncing, CmxByteTransport, MobileLocalDirectClientStoring {
    static let workspace = "00000000-0000-0000-0000-000000000011"
    static let surface = "00000000-0000-0000-0000-000000000012"
    private var listeners: [(Set<String>, AsyncStream<MobileEventEnvelope>.Continuation)] = []
    private var streamID: String?
    private var revision: UInt64 = 0
    private var columns = 60
    private var rows = 20
    private var alternate = false
    private var updated = false
    private(set) var viewportCount = 0
    private(set) var replayCount = 0
    private(set) var input = ""
    func load() -> MobileLocalDirectClientRecord? { nil }
    func save(_ record: MobileLocalDirectClientRecord) {}
    func forget() {}
    func connect() {}
    func send(_ data: Data) {}
    func receive() -> Data? { nil }
    func close() {}
    func disconnect() { listeners.forEach { $0.1.finish() }; listeners.removeAll() }
    func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
        let pair = AsyncStream<MobileEventEnvelope>.makeStream()
        listeners.append((topics, pair.continuation)); return pair.stream
    }
    func sendRequest(_ data: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
        let request = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try require(request["method"] as? String)
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "mobile.host.status":
            return try json(["mac_device_id": "00000000-0000-0000-0000-000000000001", "capabilities":
                                ["events.v1", "terminal.render_grid.v1", "terminal.render_grid.screen_anchor.v1", MobileTerminalInputDelivery.capability]])
        case "workspace.list":
            return try json(["workspaces": [["id": Self.workspace, "title": "Synthetic acceptance", "is_selected": true,
                "terminals": [["id": Self.surface, "title": "Synthetic screen fixture", "is_focused": true]],
                "surfaces": [["surface_id": Self.surface, "kind": "terminal", "title": "Synthetic screen fixture"]]]]])
        case "mobile.events.subscribe":
            try check(params["event_transport"] as? String == "control_v1")
            if params["render_grid_anchor"] != nil {
                try check(params["render_grid_anchor"] as? String == "screen")
                streamID = params["stream_id"] as? String
            }
        case "mobile.terminal.viewport":
            try checkTarget(params)
            if params["clear"] as? Bool != true {
                viewportCount += 1
                if viewportCount > 1 { try await Task.sleep(for: .milliseconds(80)) }
                columns = min(100, max(35, params["viewport_columns"] as? Int ?? columns))
                rows = min(45, max(12, params["viewport_rows"] as? Int ?? rows))
            }
            return try json(["columns": columns, "rows": rows, "render_epoch": "ui-fixture", "render_revision_floor": revision])
        case "mobile.terminal.replay":
            try checkTarget(params); try check(params["anchor"] as? String == "screen")
            replayCount += 1; revision += 1
            return try json(["surface_id": Self.surface, "workspace_id": Self.workspace, "render_grid": frame(full: true).jsonObject()])
        case "mobile.terminal.input":
            try checkTarget(params)
            let delivery = try require(MobileTerminalInputDelivery.fromRPC(parameters: params, surfaceID: UUID(uuidString: Self.surface)!))
            input += try require(params["text"] as? String)
            return try json(MobileTerminalInputAcknowledgement(status: .applied, streamID: delivery.streamID, sequence: delivery.sequence).rpcPayload)
        default: break
        }
        return Data("{}".utf8)
    }
    func updateDelta() throws { updated = true; try emit(full: false) }
    func enterAlternate() throws { alternate = true; try emit(full: true) }
    private func emit(full: Bool) throws {
        revision += 1
        let payload = try JSONEncoder().encode(frame(full: full))
        for (topics, listener) in listeners where topics.contains("terminal.render_grid") {
            listener.yield(.init(topic: "terminal.render_grid", payloadJSON: payload, streamID: streamID))
        }
    }
    private func frame(full: Bool) throws -> MobileTerminalRenderGridFrame {
        let lines = alternate ? ["SYNTHETIC Pi-style menu", "> Continue  继续", "  Inspect   查看", "  Cancel    取消", "Not a live Pi process"]
            : ["SYNTHETIC direct terminal", "中文宽字符 / screen anchor", updated ? "DELTA UPDATED  更新完成" : "FULL FRAME  等待更新", "ANSI green / red", "No network or real credentials"]
        return try MobileTerminalRenderGridFrame(surfaceID: Self.surface, stateSeq: revision,
            renderEpoch: "ui-fixture", renderRevision: revision, columns: columns, rows: rows,
            full: full, clearedRows: full ? [] : [2], styles: [.default, .init(id: 1, foreground: "#00FF00"), .init(id: 2, foreground: "#FF4444")],
            rowSpans: full ? lines.enumerated().map { .init(row: $0.offset, column: 0, styleID: $0.offset == 3 ? 1 : ($0.offset == 4 ? 2 : 0), text: $0.element) }
                : [.init(row: 2, column: 0, text: lines[2])], activeScreen: alternate ? .alternate : .primary,
            anchor: .screen, historyRows: 0, deltaBaseHistoryRows: full ? nil : 0,
            deltaBaseRenderRevision: full ? nil : revision - 1)
    }
    private func checkTarget(_ params: [String: Any]) throws {
        try check(params["workspace_id"] as? String == Self.workspace)
        try check(params["surface_id"] as? String == Self.surface)
        try check(params["client_id"] as? String != nil)
    }
    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "SyntheticTerminalFixture", code: 1) }
        return value
    }
    private func check(_ value: Bool) throws {
        guard value else { throw NSError(domain: "SyntheticTerminalFixture", code: 2) }
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
#endif
