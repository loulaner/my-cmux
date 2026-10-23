import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Synthetic store, transport, and framing-free RPC seam for controller behavior only.
actor MobileDirectClientFixture: MobileLocalDirectClientStoring, CmxByteTransport, MobileSyncing {
    static let hostID = "00000000-0000-0000-0000-000000000001"
    static let deviceID = "00000000-0000-0000-0000-000000000002"
    let opened = AsyncStream<Int>.makeStream()
    private(set) var saved: MobileLocalDirectClientRecord?
    private(set) var opens = 0
    private(set) var disconnects = 0
    private(set) var saves = 0
    private(set) var methods: [String] = []
    private var disconnected = false
    private var events: AsyncStream<MobileEventEnvelope>.Continuation?
    private var broken = false
    private var reject = false
    private var rejectList = false
    private var saveFails = false
    private var hostID = MobileDirectClientFixture.hostID
    private var openFailures = 0
    private var hold = false
    private var holdAdmission = false
    private var admissionBarrier: CheckedContinuation<Void, Never>?
    private var barrier: CheckedContinuation<Void, Never>?

    func configure(saved: MobileLocalDirectClientRecord? = nil, broken: Bool = false, reject: Bool = false,
                   saveFails: Bool = false, hostID: String = MobileDirectClientFixture.hostID, hold: Bool = false, openFailures: Int = 0, holdAdmission: Bool = false) {
        self.holdAdmission = holdAdmission
        self.openFailures = openFailures
        self.saved = saved; self.broken = broken; self.reject = reject; self.saveFails = saveFails; self.hostID = hostID; self.hold = hold
    }
    func load() throws -> MobileLocalDirectClientRecord? {
        if broken { throw MobileLocalDirectClientFileStore.Failure.invalidRecord }
        return saved
    }
    func save(_ record: MobileLocalDirectClientRecord) throws {
        if saveFails { throw MobileLocalDirectClientFileStore.Failure.unavailable }
        saves += 1; saved = record
    }
    func forget() { saved = nil; broken = false }
    func open() async throws -> any CmxByteTransport {
        opens += 1; opened.continuation.yield(opens)
        if openFailures > 0 { openFailures -= 1; throw MobileShellConnectionError.connectionClosed }
        if hold { await withCheckedContinuation { barrier = $0 } }
        return self
    }
    func release() { hold = false; barrier?.resume(); barrier = nil }
    func admit() async throws -> MobileLocalDirectClientConnection {
        if holdAdmission { await withCheckedContinuation { admissionBarrier = $0 } }
        if reject { throw MobileLocalDirectClientController.Failure.needsApproval }
        disconnected = false
        return .init(rpc: self, deviceID: Self.deviceID, token: Data(repeating: 42, count: 32))
    }
    func releaseAdmission() { holdAdmission = false; admissionBarrier?.resume(); admissionBarrier = nil }
    func connect() {}
    func receive() -> Data? { nil }
    func send(_ data: Data) {}
    func close() {}
    func disconnect() {
        guard !disconnected else { return }
        disconnected = true; disconnects += 1; events?.finish(); events = nil
    }
    func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
        let pair = AsyncStream<MobileEventEnvelope>.makeStream()
        events = pair.continuation
        return pair.stream
    }
    func denyNextListAndEmitChange() {
        rejectList = true
        events?.yield(.init(topic: "workspace.updated", payloadJSON: nil, streamID: nil))
    }
    func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64?) throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let method = try #require(object["method"] as? String)
        methods.append(method)
        if method == "mobile.host.status" {
            return try JSONSerialization.data(withJSONObject: ["mac_device_id": hostID, "capabilities": ["events.v1", "terminal.render_grid.v1"]])
        }
        if method == "mobile.events.subscribe" {
            let params = try #require(object["params"] as? [String: Any])
            #expect(params["event_transport"] as? String == "control_v1")
            return Data("{}".utf8)
        }
        if method == "mobile.terminal.viewport" {
            let params = try #require(object["params"] as? [String: Any])
            #expect(params["clear_all"] as? Bool == true)
            return Data(#"{"cleared":true}"#.utf8)
        }
        if rejectList { throw MobileShellConnectionError.authorizationFailed("synthetic refusal") }
        return Data(#"""
        {"workspaces":[{"id":"workspace-a","title":"Workspace","is_selected":true,
        "terminals":[{"id":"terminal-a","title":"Terminal","is_focused":true},{"id":"browser-a","title":"Browser","is_focused":false}],
        "surfaces":[{"surface_id":"terminal-a","kind":"terminal","title":"Terminal"},{"surface_id":"browser-a","kind":"browser","title":"Browser"}]}]}
        """#.utf8)
    }
}
