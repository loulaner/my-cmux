import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectChangesLifecycleTests {
    private nonisolated static let wsA = "10000000-0000-0000-0000-000000000001"
    private nonisolated static let wsB = "10000000-0000-0000-0000-000000000002"
    private nonisolated static let t1 = "20000000-0000-0000-0000-000000000001"
    private nonisolated static let t2 = "20000000-0000-0000-0000-000000000002"
    private nonisolated static let host = "30000000-0000-0000-0000-000000000001"
    private nonisolated static let device = "40000000-0000-0000-0000-000000000001"
    private nonisolated static let filesMethod = "mobile.workspace.changes.files"
    private nonisolated static let diffMethod = "mobile.workspace.changes.file_diff"
    private nonisolated static let readCap = CmxLocalDirectCapabilities.workspaceChangesRead

    // No framing/network: each admitted connection has an independent in-memory RPC actor.
    private actor RPC: MobileSyncing {
        let capabilities: Set<String>
        var list: Data
        var methods: [String] = []
        var topics: [Set<String>] = []
        var disconnectEffects = 0
        private var closed = false
        private var events: AsyncStream<MobileEventEnvelope>.Continuation?
        private var held: Set<String> = []
        private var pending: [String: [CheckedContinuation<Data, any Error>]] = [:]
        private var signals: [String: Int] = [:]
        private var waiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
        private var holdDisconnect = false
        private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

        init(capabilities: Set<String>, list: Data) { self.capabilities = capabilities; self.list = list }
        func hold(_ method: String) { held.insert(method) }
        func reply(_ method: String, _ result: Result<Data, any Error>) {
            pending[method]!.removeFirst().resume(with: result)
        }
        func blockDisconnect() { holdDisconnect = true }
        func releaseDisconnect() {
            holdDisconnect = false
            let waiting = disconnectWaiters; disconnectWaiters = []
            for waiter in waiting { waiter.resume() }
        }
        private func signal(_ key: String) {
            signals[key, default: 0] += 1
            let ready = waiters.filter { (signals[$0.0] ?? 0) >= $0.1 }
            waiters.removeAll { (signals[$0.0] ?? 0) >= $0.1 }
            for (_, _, waiter) in ready { waiter.resume() }
        }
        func wait(_ key: String, count: Int = 1) async {
            if (signals[key] ?? 0) >= count { return }
            await withCheckedContinuation { waiters.append((key, count, $0)) }
        }
        func disconnect() async {
            signal("disconnect")
            if closed { return }
            if holdDisconnect { await withCheckedContinuation { disconnectWaiters.append($0) } }
            guard !closed else { return }
            closed = true; disconnectEffects += 1; events?.finish(); events = nil
        }
        func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
            self.topics.append(topics)
            let channel = AsyncStream<MobileEventEnvelope>.makeStream()
            events = channel.continuation
            return channel.stream
        }
        func update(_ list: Data) {
            self.list = list
            events?.yield(.init(topic: "workspace.updated", payloadJSON: nil, streamID: nil))
        }
        func endEvents() { events?.finish() }
        func sendRequest(_ data: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(object["method"] as? String)
            let params = object["params"] as? [String: Any] ?? [:]
            methods.append(method)
            if held.contains(method) {
                return try await withCheckedThrowingContinuation { continuation in
                    pending[method, default: []].append(continuation)
                    signal(method)
                }
            }
            signal(method)
            switch method {
            case "mobile.host.status":
                return try JSONSerialization.data(withJSONObject: ["mac_device_id": MobileLocalDirectChangesLifecycleTests.host,
                    "capabilities": Array(capabilities.union(["events.v1", "terminal.render_grid.v1"]))])
            case "mobile.events.subscribe": return Data("{}".utf8)
            case "workspace.list": return list
            case "mobile.terminal.viewport":
                #expect(params["clear_all"] as? Bool == true)
                return Data(#"{"cleared":true}"#.utf8)
            case MobileLocalDirectChangesLifecycleTests.filesMethod:
                return try JSONSerialization.data(withJSONObject: ["workspace_id": params["workspace_id"] as Any,
                    "repo_root": "/fixture", "files": [["path": "file.txt"]]])
            case MobileLocalDirectChangesLifecycleTests.diffMethod:
                return try JSONSerialization.data(withJSONObject: ["path": params["path"] as Any, "unified_diff": "-old\n+new"])
            default:
                Issue.record("Unexpected RPC method")
                throw MobileShellConnectionError.invalidResponse
            }
        }
        var changesCalls: Int { methods.filter { $0 == MobileLocalDirectChangesLifecycleTests.filesMethod || $0 == MobileLocalDirectChangesLifecycleTests.diffMethod }.count }
    }

    private actor Fixture: MobileLocalDirectClientStoring, CmxByteTransport {
        let connections: [RPC]
        var record: MobileLocalDirectClientRecord?
        var admissions = 0
        private var blockSave = false
        private var saveStarted: CheckedContinuation<Void, Never>?
        private var saveBarrier: CheckedContinuation<Void, any Error>?
        init(_ connections: [RPC], record: MobileLocalDirectClientRecord?) { self.connections = connections; self.record = record }
        func load() -> MobileLocalDirectClientRecord? { record }
        func save(_ value: MobileLocalDirectClientRecord) async throws {
            if blockSave {
                try await withCheckedThrowingContinuation { continuation in
                    saveBarrier = continuation; saveStarted?.resume(); saveStarted = nil
                }
            }
            record = value
        }
        func holdSave() { blockSave = true }
        func waitForSave() async {
            if saveBarrier != nil { return }
            await withCheckedContinuation { saveStarted = $0 }
        }
        func failSave() { saveBarrier?.resume(throwing: MobileShellConnectionError.rpcError("private", "SECRET")); saveBarrier = nil }
        func forget() { record = nil }
        func connect() {}
        func receive() -> Data? { nil }
        func send(_ data: Data) {}
        func close() {}
        func admit() throws -> MobileLocalDirectClientConnection {
            guard admissions < connections.count else { throw MobileShellConnectionError.connectionClosed }
            let rpc = connections[admissions]; admissions += 1
            return .init(rpc: rpc, deviceID: MobileLocalDirectChangesLifecycleTests.device, token: Data(repeating: 9, count: 32))
        }
    }

    private func list(title: String = "initial", workspace: String = wsA, includeA: Bool = true, terminals: [String] = [t1, t2]) throws -> Data {
        let first: [String: Any] = ["id": workspace, "title": title, "is_selected": false,
            "terminals": terminals.map { ["id": $0, "title": "terminal", "is_focused": false] }]
        let second: [String: Any] = ["id": Self.wsB, "title": "other", "is_selected": false,
            "terminals": [["id": Self.t1, "title": "terminal", "is_focused": false]]]
        return try JSONSerialization.data(withJSONObject: ["workspaces": includeA ? [first, second] : [second]])
    }
    private func record() throws -> MobileLocalDirectClientRecord {
        try .init(host: "100.70.1.2", port: 49443, hostID: Self.host, deviceID: Self.device, token: Data(repeating: 9, count: 32))
    }
    private func client(_ fixture: Fixture) -> MobileLocalDirectClientController {
        .init(store: fixture, connect: { _, _ in fixture }, admit: { _, _ in try await fixture.admit() })
    }
    private func wait(_ condition: @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }
    private func connected(_ fixture: Fixture) async throws -> MobileLocalDirectClientController {
        let controller = client(fixture)
        await controller.setForeground(true)
        await wait {
            if case .error = controller.state { return true }
            return controller.state == .connected
        }
        try #require(controller.state == .connected)
        return controller
    }
    private func select(_ client: MobileLocalDirectClientController) throws -> MobileLocalDirectChangesSession {
        client.select(workspaceID: Self.wsA, surfaceID: Self.t1)
        return try #require(client.changesSession)
    }
    private func files(_ workspace: String = wsA) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["workspace_id": workspace, "repo_root": "/fixture", "files": [["path": "file.txt"]]])
    }
    private func diff() -> Data { Data(#"{"path":"file.txt","unified_diff":"late"}"#.utf8) }

    @Test(arguments: ["none", "legacy", "invalidUUID", "noSelection"])
    func eligibilityDoesNotChangeTerminalOrSendGit(mode: String) async throws {
        let caps: Set<String> = mode == "none" ? [] : mode == "legacy" ? ["workspace.changes.v1"] : [Self.readCap]
        let workspace = mode == "invalidUUID" ? "legacy-workspace" : Self.wsA
        let rpc = RPC(capabilities: caps, list: try list(workspace: workspace))
        let controller = try await connected(Fixture([rpc], record: try record()))
        if mode != "noSelection" {
            controller.select(workspaceID: workspace, surfaceID: Self.t1)
            #expect(controller.terminalSession?.workspaceID == workspace)
        }
        #expect(controller.changesSession == nil)
        #expect(await rpc.changesCalls == 0)
        await controller.setForeground(false)
    }

    @Test func sameWorkspaceReusesLoadedDiffAndInvalidSelectDoesNothing() async throws {
        let rpc = RPC(capabilities: [Self.readCap], list: try list())
        let controller = try await connected(Fixture([rpc], record: try record()))
        let changes = try select(controller)
        #expect(changes.workspaceID == Self.wsA && changes.connectionGeneration == controller.connectionGeneration)
        #expect(changes.filesState == .idle)
        #expect(await rpc.changesCalls == 0)
        changes.refresh(); await changes.listTask?.value
        changes.selectFile(path: "file.txt"); await changes.diffTask?.value
        let terminal = controller.terminalSession
        controller.select(workspaceID: Self.wsA, surfaceID: Self.t2)
        #expect(controller.changesSession === changes && controller.terminalSession !== terminal)
        #expect(changes.diffState == .ready && changes.diffResponse?.unifiedDiff == "-old\n+new")
        controller.select(workspaceID: "unknown", surfaceID: Self.t1)
        #expect(controller.changesSession === changes && controller.selectedSurfaceID == Self.t2)
        #expect(await rpc.changesCalls == 2)
        #expect(await rpc.topics == [["workspace.updated"]])
        #expect(await rpc.disconnectEffects == 0)
        await controller.setForeground(false)
    }

    @Test(arguments: [false, true])
    func workspaceSwitchDiscardsLateChanges(diffPending: Bool) async throws {
        let rpc = RPC(capabilities: [Self.readCap], list: try list())
        let controller = try await connected(Fixture([rpc], record: try record()))
        let old = try select(controller)
        if diffPending { old.refresh(); await old.listTask?.value }
        let method = diffPending ? Self.diffMethod : Self.filesMethod
        await rpc.hold(method)
        if diffPending { old.selectFile(path: "file.txt") } else { old.refresh() }
        await rpc.wait(method)
        let task = diffPending ? old.diffTask : old.listTask
        controller.select(workspaceID: Self.wsB, surfaceID: Self.t1)
        let next = try #require(controller.changesSession)
        #expect(next !== old && next.workspaceID == Self.wsB && next.filesState == .idle)
        #expect(old.filesState == .failed(.disconnected))
        old.refresh(); old.selectFile(path: "file.txt")
        await rpc.reply(method, .success(diffPending ? diff() : try files())); await task?.value
        #expect(next.filesResponse == nil && next.diffResponse == nil && old.filesResponse == nil && old.diffResponse == nil)
        #expect(await rpc.changesCalls == (diffPending ? 2 : 1))
        await controller.setForeground(false)
    }

    @Test(arguments: ["retained", "terminalRemoved", "workspaceRemoved"])
    func workspaceEventsReconcileWithoutRefreshingGit(mode: String) async throws {
        let rpc = RPC(capabilities: [Self.readCap], list: try list())
        let controller = try await connected(Fixture([rpc], record: try record()))
        let old = try select(controller)
        old.refresh(); await old.listTask?.value
        let update = try list(title: "updated", includeA: mode != "workspaceRemoved", terminals: mode == "terminalRemoved" ? [Self.t2] : [Self.t1, Self.t2])
        await rpc.update(update)
        await wait { controller.workspaces.first?.title == (mode == "workspaceRemoved" ? "other" : "updated") }
        if mode == "retained" {
            #expect(controller.changesSession === old && old.filesState == .ready)
        } else {
            #expect(controller.changesSession == nil && controller.terminalSession == nil)
            #expect(old.filesState == .failed(.disconnected))
            controller.select(workspaceID: mode == "workspaceRemoved" ? Self.wsB : Self.wsA, surfaceID: mode == "workspaceRemoved" ? Self.t1 : Self.t2)
            #expect(controller.terminalSession != nil && controller.changesSession != nil)
        }
        #expect(await rpc.changesCalls == 1)
        await controller.setForeground(false)
    }

    @Test(arguments: ["background", "disconnect", "forget", "pair", "remembered"])
    func stopInvalidatesBeforeAsyncTeardown(action: String) async throws {
        let rpc = RPC(capabilities: [Self.readCap], list: try list())
        let nextRPC = RPC(capabilities: [Self.readCap], list: try list())
        let controller = try await connected(Fixture([rpc, nextRPC], record: try record()))
        let old = try select(controller)
        await rpc.hold(Self.filesMethod)
        old.refresh(); await rpc.wait(Self.filesMethod); let pending = old.listTask
        let releasesViewport = action == "disconnect" || action == "forget"
        if releasesViewport { await rpc.hold("mobile.terminal.viewport") } else { await rpc.blockDisconnect() }
        let stopped = Task {
            switch action {
            case "background": await controller.setForeground(false)
            case "disconnect": await controller.disconnect()
            case "forget": await controller.forget()
            case "pair": await controller.pair()
            default: await controller.connectRemembered()
            }
        }
        await rpc.wait(releasesViewport ? "mobile.terminal.viewport" : "disconnect")
        #expect(controller.changesSession == nil && controller.terminalSession == nil)
        #expect(old.filesState == .failed(.disconnected) && controller.state == .disconnected)
        #expect(await rpc.disconnectEffects == 0)
        await rpc.reply(Self.filesMethod, .success(try files())); await pending?.value
        #expect(old.filesResponse == nil)
        if releasesViewport { await rpc.reply("mobile.terminal.viewport", .success(Data(#"{"cleared":true}"#.utf8))) }
        else { await rpc.releaseDisconnect() }
        await stopped.value
        if action == "pair" || action == "remembered" {
            await wait { controller.state == .connected }
            #expect(controller.changesSession !== old && controller.changesSession?.connectionGeneration != old.connectionGeneration)
        }
        #expect(await rpc.methods.filter { $0 == "mobile.terminal.viewport" }.count == (releasesViewport ? 1 : 0))
        #expect(await rpc.disconnectEffects == 1)
        #expect(await rpc.topics == [["workspace.updated"]])
        await controller.setForeground(false)
    }

    @Test(arguments: [false, true])
    func reconnectUsesNewGenerationAndNewCapabilities(missingCapability: Bool) async throws {
        let first = RPC(capabilities: [Self.readCap], list: try list())
        let second = RPC(capabilities: missingCapability ? [] : [Self.readCap], list: try list())
        let controller = try await connected(Fixture([first, second], record: try record()))
        let old = try select(controller)
        await first.hold(Self.diffMethod)
        old.refresh(); await old.listTask?.value
        old.selectFile(path: "file.txt"); await first.wait(Self.diffMethod); let pending = old.diffTask
        await controller.setForeground(false); await controller.setForeground(true)
        await wait { controller.state == .connected }
        #expect(controller.connectionGeneration > old.connectionGeneration)
        #expect(controller.terminalSession != nil)
        if missingCapability { #expect(controller.changesSession == nil) }
        else { #expect(controller.changesSession !== old && controller.changesSession?.workspaceID == Self.wsA) }
        await first.reply(Self.diffMethod, .success(diff())); await pending?.value
        #expect(old.diffResponse == nil && controller.changesSession?.diffResponse == nil)
        #expect(await second.changesCalls == 0)
        await controller.setForeground(false)
    }

    @Test func failedPersistenceNeverPublishesChanges() async throws {
        let first = RPC(capabilities: [Self.readCap], list: try list())
        let second = RPC(capabilities: [Self.readCap], list: try list())
        let fixture = Fixture([first, second], record: try record())
        let controller = try await connected(fixture)
        let old = try select(controller)
        await fixture.holdSave()
        await controller.pair()
        await fixture.waitForSave()
        #expect(controller.state != .connected && controller.changesSession == nil)
        #expect(old.filesState == .failed(.disconnected))
        await fixture.failSave()
        await wait { controller.state == .error(.saveFailed) }
        #expect(controller.changesSession == nil)
        #expect(await second.changesCalls == 0)
        await controller.setForeground(false)
    }

    @Test func oldAttemptFailureCannotRetireNewGeneration() async throws {
        let first = RPC(capabilities: [Self.readCap], list: try list())
        let pendingRPC = RPC(capabilities: [Self.readCap], list: try list())
        let newest = RPC(capabilities: [Self.readCap], list: try list())
        await pendingRPC.hold("mobile.host.status")
        await pendingRPC.blockDisconnect()
        let controller = try await connected(Fixture([first, pendingRPC, newest], record: try record()))
        let old = try select(controller)
        await first.endEvents()
        await wait { controller.state == .reconnecting }
        #expect(controller.changesSession == nil && old.filesState == .failed(.disconnected))
        controller.networkChanged()
        await pendingRPC.wait("mobile.host.status")
        let stopping = Task { await controller.connectRemembered() }
        await pendingRPC.wait("disconnect")
        // The first stop has detached its old operation/RPC before its asynchronous disconnect.
        await controller.connectRemembered()
        await wait { controller.state == .connected }
        let current = try #require(controller.changesSession)
        #expect(current.connectionGeneration > old.connectionGeneration)
        await pendingRPC.reply("mobile.host.status", .failure(MobileShellConnectionError.rpcError("private", "SECRET")))
        await pendingRPC.wait("disconnect", count: 2)
        #expect(controller.changesSession === current && current.filesState == .idle)
        await pendingRPC.releaseDisconnect()
        await stopping.value
        #expect(controller.changesSession === current && controller.state == .connected)
        await controller.setForeground(false)
    }
}
