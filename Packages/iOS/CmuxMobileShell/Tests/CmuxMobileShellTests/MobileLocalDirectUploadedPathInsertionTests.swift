import CMUXMobileCore
import CmuxMobileRPC
import CryptoKit
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectUploadedPathInsertionTests {
    private nonisolated static let workspace = DirectTerminalRPCFixture.workspace
    private nonisolated static let surface = DirectTerminalRPCFixture.surface
    private nonisolated static let other = "00000000-0000-0000-0000-000000000099"
    private nonisolated static let host = "30000000-0000-0000-0000-000000000001"
    private nonisolated static let device = "40000000-0000-0000-0000-000000000001"
    private nonisolated static let marker = String(repeating: "a", count: 64)
    private nonisolated static let caps: Set<String> = [CmxLocalDirectCapabilities.workspaceFilesList,
        CmxLocalDirectCapabilities.workspaceFilesUpload, CmxLocalDirectCapabilities.workspaceFilesPreview,
        "events.v1", "terminal.render_grid.v1", "terminal.render_grid.screen_anchor.v1", MobileTerminalInputDelivery.capability]

    private actor Peer: MobileSyncing {
        let terminal = DirectTerminalRPCFixture()
        private var events: AsyncStream<MobileEventEnvelope>.Continuation?
        func disconnect() async { events?.finish(); await terminal.disconnect() }
        func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope> {
            if topics == ["workspace.updated"] {
                let channel = AsyncStream<MobileEventEnvelope>.makeStream(); events = channel.continuation; return channel.stream
            }
            return await terminal.subscribe(to: topics)
        }
        func sendRequest(_ data: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
            let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(request["method"] as? String)
            let params = request["params"] as? [String: Any] ?? [:]
            var result: [String: Any]
            switch method {
            case "mobile.host.status":
                result = ["mac_device_id": MobileLocalDirectUploadedPathInsertionTests.host,
                          "capabilities": Array(MobileLocalDirectUploadedPathInsertionTests.caps)]
            case "workspace.list":
                result = ["workspaces": [MobileLocalDirectUploadedPathInsertionTests.workspace, MobileLocalDirectUploadedPathInsertionTests.other].map {
                    ["id": $0, "title": "workspace", "is_selected": false,
                     "terminals": [MobileLocalDirectUploadedPathInsertionTests.surface, MobileLocalDirectUploadedPathInsertionTests.other].map {
                         ["id": $0, "title": "terminal", "is_focused": false] as [String: Any]
                     }] as [String: Any]
                }]
            case "mobile.workspace.files.list":
                let path = params["path"] as? String ?? ""
                result = ["workspace_id": params["workspace_id"] as Any, "path": path,
                          "parent_path": path.isEmpty ? NSNull() : "" as Any,
                          "root_id": MobileLocalDirectUploadedPathInsertionTests.marker,
                          "entries": path.isEmpty ? [["name": "dir", "path": "dir", "kind": "directory", "size": NSNull()],
                                                      ["name": "file", "path": "file", "kind": "file", "size": 3]] : [],
                          "offset": 0, "limit": 100, "total_count": path.isEmpty ? 2 : 0, "next_offset": NSNull()]
            case "mobile.workspace.files.upload":
                let base64 = try #require(params["data_base64"] as? String)
                let bytes = try #require(Data(base64Encoded: base64))
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(params["sha256"] as? String == digest)
                let directory = try #require(params["path"] as? String)
                let name = try #require(params["file_name"] as? String)
                let path = directory.isEmpty ? name : directory + "/" + name
                result = ["workspace_id": params["workspace_id"] as Any, "path": path,
                          "root_id": params["root_id"] as Any, "byte_count": bytes.count,
                          "sha256": digest, "absolute_path": "/host/" + path]
            case "mobile.events.subscribe" where params["render_grid_anchor"] == nil:
                result = [:]
            case "mobile.terminal.viewport" where params["clear_all"] as? Bool == true:
                result = ["cleared": true]
            default: return try await terminal.sendRequest(data, timeoutNanoseconds: timeoutNanoseconds)
            }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    private actor Store: MobileLocalDirectClientStoring, CmxByteTransport {
        func load() throws -> MobileLocalDirectClientRecord? {
            try .init(host: "100.70.1.2", port: 49443, hostID: MobileLocalDirectUploadedPathInsertionTests.host,
                      deviceID: MobileLocalDirectUploadedPathInsertionTests.device, token: Data(repeating: 9, count: 32))
        }
        func save(_ value: MobileLocalDirectClientRecord) {}
        func forget() {}
        func connect() {}
        func receive() -> Data? { nil }
        func send(_ data: Data) {}
        func close() {}
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }
    private struct Context {
        let peer: Peer
        let controller: MobileLocalDirectClientController
        let files: MobileLocalDirectFilesSession
        let terminal: MobileLocalDirectTerminalSession
    }
    private func setup() async throws -> Context {
        let peer = Peer(), store = Store()
        // The transport has no IO; the admitted peer is explicitly the same owner used by files and terminal.
        let controller = MobileLocalDirectClientController(store: store, connect: { _, _ in store },
            admit: { _, _ in .init(rpc: peer, deviceID: Self.device, token: Data(repeating: 9, count: 32)) })
        await controller.setForeground(true)
        await wait { controller.state == .connected }
        controller.select(workspaceID: Self.workspace, surfaceID: Self.surface)
        let files = try #require(controller.filesSession), terminal = try #require(controller.terminalSession)
        files.refresh(); await files.requestTask?.value
        try #require(files.state == .ready)
        let sink = DirectTerminalRenderSink()
        terminal.resize(columns: 20, rows: 5, reportID: 1)
        terminal.mount(apply: sink.apply, confirmViewport: { _, _, _ in })
        await wait { terminal.state == .ready || terminal.state == .failed }
        try #require(terminal.state == .ready)
        return Context(peer: peer, controller: controller, files: files, terminal: terminal)
    }
    private func upload(_ files: MobileLocalDirectFilesSession, name: String = "space 中 '$.txt") async throws -> MobileLocalDirectFileUploadSession {
        try #require(files.prepareUpload(fileName: name, data: Data("abc".utf8), directoryRevision: files.directoryRevision))
        let child = try #require(files.uploadSession)
        child.start(); await child.requestTask?.value
        try #require(child.state == .succeeded)
        return child
    }
    private func drain(_ peer: Peer, until expected: String) async {
        let terminal = await peer.terminal
        var calls = terminal.calls.stream.makeAsyncIterator()
        while await terminal.inputs.joined() != expected {
            guard await calls.next() != nil else { Issue.record("Input stream ended"); return }
        }
    }

    @Test func explicitClickPreservesExactBytesOrderingAndConsumesOnce() async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let child = try await upload(files)
        let quote = try #require(child.shellQuotedPath)
        #expect(quote == "'/host/space 中 '\\''$.txt'")
        #expect(await peer.terminal.inputs.isEmpty)
        #expect(controller.canQueueUploadedPath(from: files, upload: child, into: terminal))
        let before = String(repeating: "x", count: 4094) + "中"
        terminal.input(Data(before.utf8))
        #expect(controller.queueUploadedPath(from: files, upload: child, into: terminal))
        terminal.input(Data("after".utf8))
        #expect(!controller.queueUploadedPath(from: files, upload: child, into: terminal))
        #expect(files.uploadSession == nil && child.uploadedFile == nil)
        await drain(peer, until: before + quote + "after")
        let chunks = await peer.terminal.inputs, deliveries = await peer.terminal.deliveries
        #expect(chunks.joined().utf8.elementsEqual((before + quote + "after").utf8))
        #expect(chunks.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\r") && !$0.contains("\n") })
        #expect(deliveries.map(\.sequence) == Array(1...UInt64(deliveries.count)))
        #expect(Set(deliveries.map(\.streamID)).count == 1)
        await controller.setForeground(false)
    }

    @Test func foreignActiveSucceededUploadCannotConsumeOwnedReceipt() async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let owned = try await upload(files, name: "owned")
        let foreignFiles = try MobileLocalDirectFilesSession(rpc: peer, workspaceID: Self.workspace,
            connectionGeneration: controller.connectionGeneration, capabilities: Self.caps)
        foreignFiles.refresh(); await foreignFiles.requestTask?.value
        let foreign = try await upload(foreignFiles, name: "foreign")
        #expect(foreign.state == .succeeded && foreign.shellQuotedPath != nil)
        #expect(!controller.canQueueUploadedPath(from: files, upload: foreign, into: terminal))
        #expect(!controller.queueUploadedPath(from: files, upload: foreign, into: terminal))
        #expect(files.uploadSession === owned && owned.state == .succeeded)
        #expect(!controller.queueUploadedPath(from: foreignFiles, upload: foreign, into: terminal))
        // A following known input creates an ordered observation barrier, including in the ownership mutant.
        terminal.input(Data("barrier".utf8))
        let expected = files.uploadSession === owned ? "barrier" : "'/host/foreign'barrier"
        await drain(peer, until: expected)
        let observed = await peer.terminal.inputs.joined()
        #expect(observed == "barrier")
        #expect(foreignFiles.uploadSession === foreign && foreign.state == .succeeded)
        foreignFiles.invalidate(); await controller.setForeground(false)
    }

    @Test func partialScalarRejectsQuietlyAndExplicitRetrySucceeds() async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let child = try await upload(files), quote = try #require(child.shellQuotedPath)
        terminal.input(Data([0xe4]))
        #expect(controller.canQueueUploadedPath(from: files, upload: child, into: terminal))
        #expect(!controller.queueUploadedPath(from: files, upload: child, into: terminal))
        #expect(files.uploadSession === child && terminal.state == .ready)
        terminal.input(Data([0xb8, 0xad]))
        await drain(peer, until: "中")
        #expect(files.uploadSession === child)
        #expect(controller.queueUploadedPath(from: files, upload: child, into: terminal))
        await drain(peer, until: "中" + quote)
        await controller.setForeground(false)
    }

    @Test func fullPendingQueueRejectsWithoutDiscardingTypedBytes() async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let child = try await upload(files), quote = try #require(child.shellQuotedPath)
        await peer.terminal.configure(holdInput: true)
        terminal.input(Data("first".utf8))
        await drain(peer, until: "first")
        let pending = String(repeating: "z", count: 65_536)
        terminal.input(Data(pending.utf8))
        #expect(controller.canQueueUploadedPath(from: files, upload: child, into: terminal))
        #expect(!controller.queueUploadedPath(from: files, upload: child, into: terminal))
        #expect(terminal.state == .ready && files.uploadSession === child && child.state == .succeeded)
        await peer.terminal.releaseInput()
        await drain(peer, until: "first" + pending)
        #expect(files.uploadSession === child)
        #expect(controller.queueUploadedPath(from: files, upload: child, into: terminal))
        await drain(peer, until: "first" + pending + quote)
        await controller.setForeground(false)
    }

    @Test func cancelledCallerAndInvalidLiteralLeaveReceiptAndTypingIntact() async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let child = try await upload(files)
        let cancelled = Task { @MainActor in controller.queueUploadedPath(from: files, upload: child, into: terminal) }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        terminal.input(Data("before".utf8))
        for text in ["", "\n", "\r", "\u{0}", "\u{1b}", "\u{2028}"] {
            #expect(!terminal.enqueueLiteralText(text))
        }
        terminal.input(Data("after".utf8))
        await drain(peer, until: "beforeafter")
        #expect(files.uploadSession === child && child.state == .succeeded && terminal.state == .ready)
        await controller.setForeground(false)
    }

    @Test func reconnectRejectsCapturedGeneration() async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let child = try await upload(files), generation = controller.connectionGeneration
        await controller.setForeground(false)
        await controller.setForeground(true)
        await wait { controller.state == .connected }
        #expect(controller.connectionGeneration != generation)
        #expect(controller.filesSession !== files && controller.terminalSession !== terminal)
        #expect(!controller.queueUploadedPath(from: files, upload: child, into: terminal))
        #expect(await peer.terminal.inputs.isEmpty)
        await controller.setForeground(false)
    }

    @Test(arguments: ["refresh", "directory", "preview", "close", "invalidate", "surface", "aba", "workspace", "unmount", "viewport"])
    func retiredOrUnreadySelectionRejects(mode: String) async throws {
        let context = try await setup()
        let peer = context.peer, controller = context.controller, files = context.files, terminal = context.terminal
        let child = try await upload(files)
        switch mode {
        case "refresh": files.refresh(); await files.requestTask?.value
        case "directory": files.openDirectory(path: "dir"); await files.requestTask?.value
        case "preview": #expect(files.openFile(path: "file"))
        case "close": files.closeUpload()
        case "invalidate": files.invalidate()
        case "surface": controller.select(workspaceID: Self.workspace, surfaceID: Self.other)
        case "aba":
            controller.select(workspaceID: Self.workspace, surfaceID: Self.other)
            controller.select(workspaceID: Self.workspace, surfaceID: Self.surface)
        case "workspace": controller.select(workspaceID: Self.other, surfaceID: Self.surface)
        case "unmount": terminal.unmount()
        default:
            await peer.terminal.configure(holdViewport: true)
            terminal.resize(columns: 21, rows: 5, reportID: 2)
        }
        let ownerBefore = files.uploadSession
        #expect(!controller.canQueueUploadedPath(from: files, upload: child, into: terminal))
        #expect(!controller.queueUploadedPath(from: files, upload: child, into: terminal))
        #expect(files.uploadSession === ownerBefore)
        #expect(await peer.terminal.inputs.isEmpty)
        await peer.terminal.releaseViewport()
        await controller.setForeground(false)
    }
}
