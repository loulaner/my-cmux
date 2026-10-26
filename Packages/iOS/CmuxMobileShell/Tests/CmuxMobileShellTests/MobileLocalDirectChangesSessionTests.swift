import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectChangesSessionTests {
    typealias Session = MobileLocalDirectChangesSession
    private static let workspace = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private static let path = "目录/with space[1].swift"

    private actor RPC: MobileSyncing {
        var requests: [Data] = []
        var disconnects = 0
        var subscriptions = 0
        var activity: [Int] { [requests.count, disconnects, subscriptions] }
        var cancelled: [Int: Bool] = [:]
        private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
        private var barriers: [(Int, CheckedContinuation<Void, Never>)] = []
        func disconnect() { disconnects += 1 }
        func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
            subscriptions += 1
            return AsyncStream { $0.finish() }
        }
        func sendRequest(_ data: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
            let index = requests.count
            requests.append(data)
            // Intentionally ignores cancellation until the test releases the response.
            let result: Result<Data, any Error>
            do {
                let response = try await withCheckedThrowingContinuation { continuation in
                    pending[index] = continuation
                    let ready = barriers.filter { $0.0 <= requests.count }
                    barriers.removeAll { $0.0 <= requests.count }
                    for (_, barrier) in ready { barrier.resume() }
                }
                result = .success(response)
            } catch { result = .failure(error) }
            cancelled[index] = Task.isCancelled
            return try result.get()
        }
        func waitForCalls(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { barriers.append((count, $0)) }
        }
        func reply(_ index: Int, _ result: Result<Data, any Error>) {
            pending.removeValue(forKey: index)!.resume(with: result)
        }
    }

    private func make(_ rpc: RPC, capabilities: Set<String> = [CmxLocalDirectCapabilities.workspaceChangesRead]) throws -> Session {
        try Session(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 7, capabilities: capabilities)
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
    private func list(_ paths: [String] = [Self.path]) throws -> Data {
        try data(["workspace_id": Self.workspace.uppercased(), "repo_root": "/private/fixture",
                  "files": paths.map { ["path": $0, "status": "modified"] }])
    }
    private func load(_ session: Session, _ rpc: RPC, paths: [String] = [Self.path]) async throws {
        let index = await rpc.requests.count
        session.refresh()
        await rpc.waitForCalls(index + 1)
        await rpc.reply(index, .success(try list(paths)))
        await session.listTask?.value
        #expect(session.filesState == .ready)
    }

    @Test func constructorAndCapabilityGatesHaveNoSideEffects() async throws {
        let rpc = RPC()
        #expect(throws: Session.Failure.invalidSelection) {
            try Session(rpc: rpc, workspaceID: "invalid", connectionGeneration: 0, capabilities: [])
        }
        for caps in [Set<String>(), Set(["workspace.changes.v1"])] {
            let session = try make(rpc, capabilities: caps)
            #expect(session.filesState == .idle)
            session.refresh(); session.selectFile(path: Self.path)
            #expect(session.filesState == .failed(.unsupported))
            #expect(session.diffState == .failed(.unsupported))
        }
        let capable = try make(rpc)
        #expect(capable.workspaceID == Self.workspace && capable.connectionGeneration == 7)
        #expect(capable.filesState == .idle && capable.diffState == .idle)
        #expect(await rpc.requests.isEmpty)
        #expect(await rpc.activity == [0, 0, 0])
    }

    @Test func requestsAreNarrowAndResponsesBindToSelection() async throws {
        let rpc = RPC(), session = try make(rpc)
        try await load(session, rpc)
        session.selectFile(path: Self.path)
        await rpc.waitForCalls(2)
        await rpc.reply(1, .success(try data(["path": Self.path, "unified_diff": "-old\n+new"])))
        await session.diffTask?.value
        #expect(session.diffState == .ready && session.diffResponse?.unifiedDiff == "-old\n+new")
        let requests = try await rpc.requests.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        #expect(requests.map { $0["method"] as? String } == ["mobile.workspace.changes.files", "mobile.workspace.changes.file_diff"])
        let ids = requests.compactMap { $0["id"] as? String }
        #expect(ids.count == 2 && Set(ids).count == 2 && ids.allSatisfy { UUID(uuidString: $0) != nil })
        let first = try #require(requests[0]["params"] as? [String: Any])
        let second = try #require(requests[1]["params"] as? [String: Any])
        #expect(Set(first.keys) == ["workspace_id"] && first["workspace_id"] as? String == Self.workspace)
        #expect(Set(second.keys) == ["workspace_id", "path", "max_lines"])
        #expect(second["workspace_id"] as? String == Self.workspace && second["path"] as? String == Self.path)
        #expect(second["max_lines"] as? Int == 6000)
        session.selectFile(path: "not-listed")
        #expect(session.diffState == .failed(.invalidSelection) && session.diffResponse == nil && session.selectedPath == nil)
        #expect(session.filesState == .ready)
        #expect(await rpc.requests.count == 2)
    }

    @Test func emptyListAndBinaryEmptyDiffAreValid() async throws {
        let rpc = RPC(), session = try make(rpc)
        session.selectFile(path: Self.path)
        #expect(session.diffState == .failed(.invalidSelection))
        #expect(await rpc.requests.isEmpty)
        try await load(session, rpc, paths: [])
        #expect(session.filesResponse?.files.isEmpty == true)
        try await load(session, rpc)
        session.selectFile(path: Self.path); await rpc.waitForCalls(3)
        await rpc.reply(2, .success(try data(["path": Self.path, "unified_diff": "", "is_binary": true])))
        await session.diffTask?.value
        #expect(session.diffState == .ready && session.diffResponse?.isBinary == true)
    }

    @Test(arguments: ["", "/absolute", "../x", "a/../b", "a/./b", "a//b", "a/", "\0bad"])
    func invalidPathsRejectWholeList(path: String) async throws {
        let rpc = RPC(), session = try make(rpc)
        session.refresh(); await rpc.waitForCalls(1)
        await rpc.reply(0, .success(try list([Self.path, path])))
        await session.listTask?.value
        #expect(session.filesState == .failed(.invalidResponse) && session.filesResponse == nil)
    }

    @Test(arguments: ["workspace", "missingWorkspace", "root", "missingRoot", "files", "missingFiles", "duplicate", "oldPath", "oldType", "emptyRoot", "entry", "pathType"])
    func malformedListsCannotUseDecoderDefaults(kind: String) async throws {
        let rpc = RPC(), session = try make(rpc)
        var object: [String: Any] = ["workspace_id": Self.workspace, "repo_root": "/repo", "files": [["path": Self.path]]]
        switch kind {
        case "workspace": object["workspace_id"] = UUID().uuidString
        case "missingWorkspace": object.removeValue(forKey: "workspace_id")
        case "root": object["repo_root"] = "relative"
        case "missingRoot": object.removeValue(forKey: "repo_root")
        case "files": object["files"] = "wrong"
        case "missingFiles": object.removeValue(forKey: "files")
        case "duplicate": object["files"] = [["path": Self.path], ["path": Self.path]]
        case "oldPath": object["files"] = [["path": Self.path, "old_path": "../old"]]
        case "oldType": object["files"] = [["path": Self.path, "old_path": 5]]
        case "emptyRoot": object["repo_root"] = ""
        case "entry": object["files"] = ["not an object"]
        default: object["files"] = [["path": 123]]
        }
        session.refresh(); await rpc.waitForCalls(1)
        await rpc.reply(0, .success(try data(object))); await session.listTask?.value
        #expect(session.filesState == .failed(.invalidResponse) && session.filesResponse == nil)
    }

    @Test(arguments: ["missing", "wrongType", "wrongPath", "missingPath"])
    func malformedDiffsAreRejected(kind: String) async throws {
        let rpc = RPC(), session = try make(rpc)
        try await load(session, rpc)
        var object: [String: Any] = ["path": Self.path, "unified_diff": "text"]
        switch kind {
        case "missing": object.removeValue(forKey: "unified_diff")
        case "wrongType": object["unified_diff"] = 1
        case "wrongPath": object["path"] = "other"
        default: object.removeValue(forKey: "path")
        }
        session.selectFile(path: Self.path); await rpc.waitForCalls(2)
        await rpc.reply(1, .success(try data(object))); await session.diffTask?.value
        #expect(session.diffState == .failed(.invalidResponse) && session.diffResponse == nil)
    }

    @Test func supersededListsAndDiffsCannotPublish() async throws {
        let rpc = RPC(), session = try make(rpc)
        session.refresh(); await rpc.waitForCalls(1); let oldList = session.listTask
        session.refresh(); await rpc.waitForCalls(2)
        await rpc.reply(1, .success(try list(["a", "b"]))); await session.listTask?.value
        await rpc.reply(0, .success(try list(["stale"]))); await oldList?.value
        #expect(session.filesResponse?.files.map(\.path) == ["a", "b"])
        #expect(await rpc.cancelled[0] == true)
        session.selectFile(path: "a"); await rpc.waitForCalls(3); let oldDiff = session.diffTask
        session.selectFile(path: "b"); await rpc.waitForCalls(4)
        await rpc.reply(3, .success(try data(["path": "b", "unified_diff": "latest"]))); await session.diffTask?.value
        await rpc.reply(2, .success(try data(["path": "a", "unified_diff": "stale"]))); await oldDiff?.value
        #expect(session.selectedPath == "b" && session.diffResponse?.unifiedDiff == "latest")
        #expect(await rpc.cancelled[2] == true)
    }

    @Test func refreshInvalidatesOldDiffAndFailureClearsList() async throws {
        let rpc = RPC(), session = try make(rpc)
        try await load(session, rpc)
        session.selectFile(path: Self.path); await rpc.waitForCalls(2); let oldDiff = session.diffTask
        session.refresh(); await rpc.waitForCalls(3)
        #expect(session.filesResponse == nil && session.diffResponse == nil && session.selectedPath == nil)
        await rpc.reply(2, .failure(MobileShellConnectionError.rpcError("not_a_repo", "SECRET")))
        await session.listTask?.value
        await rpc.reply(1, .success(try data(["path": Self.path, "unified_diff": "late"]))); await oldDiff?.value
        #expect(session.filesState == .failed(.notRepository) && session.diffResponse == nil)
        #expect(await rpc.cancelled[1] == true)
        session.selectFile(path: Self.path)
        #expect(session.diffState == .failed(.invalidSelection))
        #expect(await rpc.requests.count == 3)
    }

    @Test func invalidateIsPermanentAndNeverDisconnectsSharedRPC() async throws {
        let rpc = RPC(), session = try make(rpc)
        try await load(session, rpc)
        session.selectFile(path: Self.path); await rpc.waitForCalls(2); let oldDiff = session.diffTask
        session.refresh(); await rpc.waitForCalls(3); let oldList = session.listTask
        session.invalidate(); session.invalidate(); session.refresh(); session.selectFile(path: Self.path)
        await rpc.reply(1, .success(try data(["path": Self.path, "unified_diff": "late"]))); await oldDiff?.value
        await rpc.reply(2, .success(try list())); await oldList?.value
        #expect(session.filesState == .failed(.disconnected) && session.diffState == .failed(.disconnected))
        #expect(session.filesResponse == nil && session.diffResponse == nil && session.selectedPath == nil)
        #expect(await rpc.activity == [3, 0, 0])
    }

    @Test func deinitDoesNotStayRetainedByPendingRPC() async throws {
        let rpc = RPC()
        var session: Session? = try make(rpc)
        weak var weakSession = session
        session?.refresh(); await rpc.waitForCalls(1)
        let task = session?.listTask
        session = nil
        #expect(weakSession == nil)
        await rpc.reply(0, .success(try list())); await task?.value
        #expect(await rpc.cancelled[0] == true)
        #expect(await rpc.disconnects == 0)
    }

    @Test(arguments: [
        ("method_not_found", Session.Failure.unsupported), ("capability_disabled", .unsupported),
        ("not_a_repo", .notRepository), ("file_transfer_disabled", .permissionDenied),
        ("forbidden", .permissionDenied), ("permission_denied", .permissionDenied),
        ("connection_closed", .disconnected), ("unknown_secret_code", .unavailable),
    ])
    func serverErrorsAreSafeAndOnlyExplicitRefreshRetries(code: String, expected: Session.Failure) async throws {
        let rpc = RPC(), session = try make(rpc)
        session.refresh(); await rpc.waitForCalls(1)
        await rpc.reply(0, .failure(MobileShellConnectionError.rpcError(code, "SECRET credential/path")))
        await session.listTask?.value
        #expect(session.filesState == .failed(expected) && session.filesResponse == nil)
        #expect(await rpc.requests.count == 1)
        try await load(session, rpc)
        #expect(await rpc.requests.count == 2)
    }

    @Test func diffFailuresAndLateCancellationDoNotOverwriteNewState() async throws {
        let rpc = RPC(), session = try make(rpc)
        try await load(session, rpc)
        session.selectFile(path: Self.path); await rpc.waitForCalls(2)
        let old = session.diffTask
        session.selectFile(path: Self.path); await rpc.waitForCalls(3)
        await rpc.reply(2, .success(try data(["path": Self.path, "unified_diff": "current"])))
        await session.diffTask?.value
        await rpc.reply(1, .failure(CancellationError())); await old?.value
        #expect(session.diffState == .ready && session.diffResponse?.unifiedDiff == "current")
        let errors: [(any Error, Session.LoadState)] = [
            (MobileShellConnectionError.rpcError("forbidden", "SECRET"), .failed(.permissionDenied)),
            (MobileShellConnectionError.connectionClosed, .failed(.disconnected)),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "SECRET")), .failed(.invalidResponse)),
            (CancellationError(), .idle),
        ]
        for (offset, item) in errors.enumerated() {
            session.selectFile(path: Self.path); await rpc.waitForCalls(offset + 4)
            await rpc.reply(offset + 3, .failure(item.0)); await session.diffTask?.value
            #expect(session.diffState == item.1 && session.diffResponse == nil)
            #expect(session.filesState == .ready)
        }
    }

    @Test func validRenameAndNullOldPathKeepOriginalStrings() async throws {
        let rpc = RPC(), session = try make(rpc)
        session.refresh(); await rpc.waitForCalls(1)
        let response = try data(["workspace_id": Self.workspace, "repo_root": "/repo", "files": [
            ["path": Self.path, "old_path": "old name[2]"], ["path": "other", "old_path": NSNull()],
        ]])
        await rpc.reply(0, .success(response)); await session.listTask?.value
        #expect(session.filesState == .ready)
        #expect(session.filesResponse?.files.map(\.path) == [Self.path, "other"])
        #expect(session.filesResponse?.files.first?.oldPath == "old name[2]")
        #expect(session.filesResponse?.files.last?.oldPath == nil)
    }

    @Test func transportDecodeAndUnexpectedCancellationAreSafe() async throws {
        let rpc = RPC(), session = try make(rpc)
        let failures: [(any Error, Session.LoadState)] = [
            (MobileShellConnectionError.connectionClosed, .failed(.disconnected)),
            (MobileShellConnectionError.invalidResponse, .failed(.invalidResponse)),
            (MobileShellConnectionError.requestTimedOut, .failed(.unavailable)),
            (CancellationError(), .idle),
        ]
        for (index, pair) in failures.enumerated() {
            session.refresh(); await rpc.waitForCalls(index + 1)
            await rpc.reply(index, .failure(pair.0)); await session.listTask?.value
            #expect(session.filesState == pair.1)
        }
        session.refresh(); await rpc.waitForCalls(5)
        await rpc.reply(4, .success(Data("not JSON".utf8))); await session.listTask?.value
        #expect(session.filesState == .failed(.invalidResponse))
    }
}
