import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectFilesSessionTests {
    private static let workspace = "10000000-0000-0000-0000-000000000001"

    private actor RPC: MobileSyncing {
        var requests: [Data] = []
        var disconnects = 0
        var subscriptions = 0
        private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func sendRequest(_ request: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
            #expect(timeoutNanoseconds == nil)
            let index = requests.count
            requests.append(request)
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = waiters.filter { requests.count >= $0.0 }
                waiters.removeAll { requests.count >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        func wait(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func reply(_ index: Int, _ result: Result<Data, any Error>) { pending.removeValue(forKey: index)?.resume(with: result) }
        func disconnect() { disconnects += 1 }
        func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
            subscriptions += 1
            return AsyncStream { $0.finish() }
        }
    }
    private func model(_ rpc: RPC, capable: Bool = true) throws -> MobileLocalDirectFilesSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 7,
                  capabilities: capable ? [CmxLocalDirectCapabilities.workspaceFilesList] : [CmxLocalDirectCapabilities.workspaceChangesRead])
    }
    private func object(_ names: [String] = [], path: String = "", offset: Int = 0, total: Int? = nil,
                        kind: String = "file", limit: Int = 100) -> [String: Any] {
        let count = total ?? offset + names.count
        let end = offset + names.count
        return ["workspace_id": Self.workspace, "path": path,
                "parent_path": path.isEmpty ? NSNull() : path.split(separator: "/").dropLast().joined(separator: "/") as Any,
                "entries": names.map { ["name": $0, "path": path.isEmpty ? $0 : path + "/" + $0,
                                        "kind": kind, "size": kind == "file" ? 1 as Any : NSNull()] },
                "offset": offset, "limit": limit, "total_count": count, "next_offset": end < count ? end as Any : NSNull()]
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func names(_ range: Range<Int>) -> [String] { range.map { String(format: "f%05d", $0) } }
    private func finish(_ model: MobileLocalDirectFilesSession, _ rpc: RPC, index: Int, value: [String: Any]) async throws {
        await rpc.wait(index + 1)
        let task = model.requestTask
        await rpc.reply(index, .success(try data(value)))
        await task?.value
    }
    private func empty(_ model: MobileLocalDirectFilesSession) {
        #expect(model.entries.isEmpty && model.totalCount == nil && model.nextOffset == nil)
    }

    @Test func strictDTOValidRootsChildrenKindsAndLongNames() throws {
        for kind in ["file", "directory", "symbolicLink", "other"] {
            let page = try MobileWorkspaceFileListResponse.decode(data(object(["%2e%2e", "~", "中文 []"], path: "a/b", kind: kind)))
            #expect(page.parentPath == "a" && page.path == "a/b" && page.entries.count == 3)
            #expect(page.entries[0].size == (kind == "file" ? 1 : nil))
        }
        let long = String(repeating: "中", count: 200)
        #expect(try MobileWorkspaceFileListResponse.decode(data(object([long]))).entries[0].name == long)
        let path = String(repeating: "x", count: 4096)
        #expect(try MobileWorkspaceFileListResponse.decode(data(object(["child"], path: path))).entries[0].path.utf8.count > 4096)
        let page = try MobileWorkspaceFileListResponse.decode(data(object(names(100..<101), offset: 100, total: 101)))
        #expect(page.offset == 100 && page.nextOffset == nil)
        var extended = object(); extended["future"] = true
        #expect(try MobileWorkspaceFileListResponse.decode(data(extended)).parentPath == nil)
    }

    @Test func strictDTORejectsMalformedPagesAndEntries() throws {
        var invalid: [[String: Any]] = []
        for key in ["workspace_id", "path", "parent_path", "entries", "offset", "limit", "total_count", "next_offset"] {
            var value = object(["a"]); value.removeValue(forKey: key); invalid.append(value)
        }
        let badFields: [(String, Any)] = [("workspace_id", "invalid"), ("workspace_id", true), ("path", NSNull()),
            ("path", "/a"), ("path", ".."), ("path", "a//b"), ("path", "a/"), ("path", "a/../b"), ("path", "a\0b"),
            ("path", String(repeating: "x", count: 4097)), ("parent_path", ""), ("parent_path", true),
            ("offset", true), ("offset", -1), ("offset", Int.max), ("offset", 1.5), ("limit", false), ("limit", 0),
            ("limit", 101), ("limit", "100"), ("total_count", 10001), ("total_count", -1), ("total_count", true),
            ("total_count", 2), ("next_offset", 0), ("next_offset", true), ("entries", NSNull())]
        for (key, replacement) in badFields { var value = object(["a"]); value[key] = replacement; invalid.append(value) }
        let entryFields: [(String, Any)] = [("name", ""), ("name", "."), ("name", ".."), ("name", "a/b"),
            ("name", "a\0b"), ("name", String(repeating: "中", count: 1366)), ("path", "/a"), ("path", "../a"),
            ("path", "other"), ("kind", "unknown"), ("kind", true), ("size", true), ("size", -1), ("size", 1.5), ("size", NSNull())]
        for (key, replacement) in entryFields {
            var value = object(["a"]); var entry = (value["entries"] as? [[String: Any]])?.first ?? [:]
            entry[key] = replacement; value["entries"] = [entry]; invalid.append(value)
        }
        for key in ["name", "path", "kind", "size"] {
            var value = object(["a"]); var entry = (value["entries"] as? [[String: Any]])?.first ?? [:]
            entry.removeValue(forKey: key); value["entries"] = [entry]; invalid.append(value)
        }
        for kind in ["directory", "symbolicLink", "other"] {
            var value = object(["a"], kind: kind); var entry = (value["entries"] as? [[String: Any]])?.first ?? [:]
            entry["size"] = 1; value["entries"] = [entry]; invalid.append(value)
        }
        invalid += [object(["b", "a"]), object(["a", "a"]), object(["e\u{301}", "é"])]
        var spoof = object(["é"]); spoof["entries"] = [["name": "é", "path": "e\u{301}", "kind": "file", "size": 1]]; invalid.append(spoof)
        var parent = object(["a"], path: "e\u{301}/child"); parent["parent_path"] = "é"; invalid.append(parent)
        var stalled = object(names(0..<100), total: 101); stalled["next_offset"] = 0; invalid.append(stalled)
        for value in invalid {
            do { _ = try MobileWorkspaceFileListResponse.decode(data(value)); Issue.record("Malformed page accepted") }
            catch is DecodingError {}
        }
    }

    @Test func idleUnsupportedAndWireContract() async throws {
        let rpc = RPC(), session = try model(rpc), unsupported = try model(rpc, capable: false)
        #expect(session.state == .idle && session.currentPath == "" && session.parentPath == nil)
        session.goToParent(); session.loadNextPage(); session.openDirectory(path: "unknown")
        unsupported.refresh(); #expect(unsupported.state == .failed(.unsupported))
        #expect(await rpc.requests.isEmpty)
        #expect(throws: MobileLocalDirectFilesSession.Failure.invalidSelection) {
            try MobileLocalDirectFilesSession(rpc: rpc, workspaceID: "invalid", connectionGeneration: 0, capabilities: [])
        }
        for index in 0..<2 { session.refresh(); try await finish(session, rpc, index: index, value: object()) }
        var ids = Set<String>()
        for request in await rpc.requests {
            let wire = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let identifier = try #require(wire["id"] as? String)
            #expect(UUID(uuidString: identifier) != nil && ids.insert(identifier).inserted)
            #expect(wire["method"] as? String == "mobile.workspace.files.list")
            let params = try #require(wire["params"] as? [String: Any])
            #expect(Set(params.keys) == ["workspace_id", "path", "offset", "limit"])
            #expect(params["workspace_id"] as? String == Self.workspace && params["path"] as? String == "")
            #expect(params["offset"] as? Int == 0 && params["limit"] as? Int == 100)
        }
        session.invalidate(); session.refresh(); session.goToParent(); session.loadNextPage(); session.openDirectory(path: "a")
        #expect(await rpc.requests.count == 2)
        #expect(await rpc.disconnects == 0)
        #expect(await rpc.subscriptions == 0)
    }

    @Test func directoryNavigationAndLongChildRefusal() async throws {
        let rpc = RPC(), session = try model(rpc)
        session.refresh(); try await finish(session, rpc, index: 0, value: object(["%2e%2e"], kind: "directory"))
        session.openDirectory(path: "%2e%2e")
        #expect(session.currentPath == "%2e%2e" && session.parentPath == "")
        session.openDirectory(path: "ignored"); #expect(session.state == .loading)
        try await finish(session, rpc, index: 1, value: object(["~"], path: "%2e%2e", kind: "directory"))
        session.openDirectory(path: "%2e%2e/~")
        try await finish(session, rpc, index: 2, value: object(path: "%2e%2e/~"))
        session.goToParent(); try await finish(session, rpc, index: 3, value: object(path: "%2e%2e"))
        session.goToParent(); try await finish(session, rpc, index: 4, value: object())
        session.goToParent(); #expect(await rpc.requests.count == 5)
        let long = String(repeating: "x", count: 4096)
        session.refresh(); try await finish(session, rpc, index: 5, value: object([long], kind: "directory"))
        session.openDirectory(path: long); try await finish(session, rpc, index: 6, value: object(["child"], path: long, kind: "directory"))
        #expect(session.entries.count == 1)
        session.openDirectory(path: long + "/child")
        #expect(session.state == .failed(.invalidSelection) && session.currentPath == long)
        empty(session); #expect(await rpc.requests.count == 7)
    }

    @Test(arguments: ["file", "symbolicLink", "other", "unknown", "unicode"])
    func invalidNavigationNeverRequests(kind: String) async throws {
        let rpc = RPC(), session = try model(rpc)
        session.refresh()
        try await finish(session, rpc, index: 0, value: object([kind == "unicode" ? "é" : "a"], kind: ["unknown", "unicode"].contains(kind) ? "directory" : kind))
        session.openDirectory(path: kind == "unknown" ? "not-listed" : kind == "unicode" ? "e\u{301}" : "a")
        #expect(session.state == .failed(.invalidSelection) && session.currentPath == "")
        empty(session); #expect(await rpc.requests.count == 1)
    }

    @Test func paginationSingleFlightAndMaximum() async throws {
        let rpc = RPC(), session = try model(rpc)
        session.refresh(); session.loadNextPage()
        for index in 0..<100 {
            if index > 0 {
                session.loadNextPage(); session.loadNextPage(); session.openDirectory(path: "unknown")
                #expect(session.entries.count == index * 100 && session.state == .loading)
            }
            try await finish(session, rpc, index: index, value: object(names(index * 100..<(index + 1) * 100), offset: index * 100, total: 10000))
            #expect(session.entries.count == (index + 1) * 100 && session.state == .ready)
        }
        #expect(session.nextOffset == nil && session.totalCount == 10000)
        session.loadNextPage(); #expect(await rpc.requests.count == 100)
    }

    @Test(arguments: ["count", "order", "duplicate", "unicode", "offset", "workspace", "path", "limit"])
    func paginationRejectsDrift(mode: String) async throws {
        let rpc = RPC(), session = try model(rpc)
        let first = mode == "unicode" ? names(0..<99).map { "d" + $0 } + ["e\u{301}"] : names(0..<100)
        session.refresh(); try await finish(session, rpc, index: 0, value: object(first, total: 101))
        try #require(session.state == .ready)
        session.loadNextPage()
        var page = object(["z"], offset: 100, total: 101)
        switch mode {
        case "count": page = object(["y", "z"], offset: 100, total: 102)
        case "order": page = object(["a"], offset: 100, total: 101)
        case "duplicate": page = object(["f00099"], offset: 100, total: 101)
        case "unicode": page = object(["é"], offset: 100, total: 101)
        case "offset": page = object(["z"], offset: 99, total: 100)
        case "workspace": page["workspace_id"] = UUID().uuidString
        case "path": page = object(["z"], path: "other", offset: 100, total: 101)
        default: page["limit"] = 1
        }
        try await finish(session, rpc, index: 1, value: page)
        #expect(session.state == .failed(mode == "count" ? .directoryChanged : .invalidResponse))
        empty(session)
    }

    @Test func lateResultsRefreshParentAndInvalidation() async throws {
        let rpc = RPC(), session = try model(rpc)
        session.refresh(); await rpc.wait(1); let old = session.requestTask
        session.refresh(); try await finish(session, rpc, index: 1, value: object(["dir"], kind: "directory"))
        await rpc.reply(0, .failure(MobileShellConnectionError.rpcError("private", "SECRET"))); await old?.value
        #expect(session.state == .ready && session.entries.first?.name == "dir")
        session.openDirectory(path: "dir"); await rpc.wait(3); let child = session.requestTask
        session.goToParent(); try await finish(session, rpc, index: 3, value: object())
        await rpc.reply(2, .success(try data(object(["late"], path: "dir")))); await child?.value
        #expect(session.currentPath == "" && session.entries.isEmpty && session.state == .ready)
        session.refresh(); await rpc.wait(5); let retired = session.requestTask
        session.invalidate(); await rpc.reply(4, .success(try data(object(["late"])))); await retired?.value
        #expect(session.currentPath == "" && session.state == .failed(.disconnected)); empty(session)
        #expect(await rpc.disconnects == 0)
        #expect(await rpc.subscriptions == 0)
    }

    @Test func refreshDiscardsPendingSecondPageAndParentRecoversFromFailure() async throws {
        let rpc = RPC(), session = try model(rpc)
        session.refresh(); try await finish(session, rpc, index: 0, value: object(names(0..<100), total: 101))
        session.loadNextPage(); await rpc.wait(2); let oldPage = session.requestTask
        session.refresh(); empty(session)
        try await finish(session, rpc, index: 2, value: object(["dir"], kind: "directory"))
        await rpc.reply(1, .success(try data(object(["z"], offset: 100, total: 101)))); await oldPage?.value
        #expect(session.entries.map(\.name) == ["dir"] && session.totalCount == 1)
        session.openDirectory(path: "dir"); await rpc.wait(4); let task = session.requestTask
        await rpc.reply(3, .success(Data("{malformed".utf8))); await task?.value
        #expect(session.state == .failed(.invalidResponse) && session.currentPath == "dir"); empty(session)
        session.goToParent(); try await finish(session, rpc, index: 4, value: object())
        #expect(session.state == .ready && session.currentPath == "")
    }

    @Test func UUIDIdentityPreservesWireSpellingAndPathContextUsesBytes() async throws {
        let rpc = RPC()
        let uuid = "ABCDEFAB-0000-0000-0000-000000000001"
        let session = try MobileLocalDirectFilesSession(rpc: rpc, workspaceID: uuid, connectionGeneration: 7,
            capabilities: [CmxLocalDirectCapabilities.workspaceFilesList])
        session.refresh()
        var root = object(["e\u{301}"], kind: "directory"); root["workspace_id"] = uuid.lowercased()
        try await finish(session, rpc, index: 0, value: root)
        #expect(session.state == .ready && session.workspaceID == uuid)
        let request = try #require(await rpc.requests.first)
        let wire = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect((wire["params"] as? [String: Any])?["workspace_id"] as? String == uuid)
        session.openDirectory(path: "e\u{301}")
        var child = object(path: "é"); child["workspace_id"] = uuid
        try await finish(session, rpc, index: 1, value: child)
        #expect(session.state == .failed(.invalidResponse)); empty(session)
    }

    @Test func failuresAreSafeAndPageTwoClearsEverything() async throws {
        let cases: [(any Error, MobileLocalDirectFilesSession.Failure?)] = [
            (MobileShellConnectionError.rpcError("method_not_found", "SECRET"), .unsupported),
            (MobileShellConnectionError.rpcError("capability_disabled", "SECRET"), .unsupported),
            (MobileShellConnectionError.rpcError("unsupported_workspace", "SECRET"), .unsupportedWorkspace),
            (MobileShellConnectionError.rpcError("file_transfer_disabled", "SECRET"), .permissionDenied),
            (MobileShellConnectionError.rpcError("forbidden", "SECRET"), .permissionDenied),
            (MobileShellConnectionError.rpcError("permission_denied", "SECRET"), .permissionDenied),
            (MobileShellConnectionError.rpcError("directory_not_found", "SECRET"), .directoryUnavailable),
            (MobileShellConnectionError.rpcError("not_a_directory", "SECRET"), .directoryUnavailable),
            (MobileShellConnectionError.rpcError("workspace_not_found", "SECRET"), .directoryUnavailable),
            (MobileShellConnectionError.rpcError("workspace_unavailable", "SECRET"), .directoryUnavailable),
            (MobileShellConnectionError.rpcError("workspace_changed", "SECRET"), .directoryChanged),
            (MobileShellConnectionError.rpcError("limit_exceeded", "SECRET"), .limitExceeded),
            (MobileShellConnectionError.rpcError("connection_closed", "SECRET"), .disconnected),
            (MobileShellConnectionError.rpcError("disconnected", "SECRET"), .disconnected),
            (MobileShellConnectionError.connectionClosed, .disconnected),
            (MobileShellConnectionError.invalidResponse, .invalidResponse),
            (MobileShellConnectionError.rpcError("busy", "SECRET"), .unavailable),
            (MobileShellConnectionError.rpcError("cancelled", "SECRET"), .unavailable),
            (NSError(domain: "SECRET", code: 1), .unavailable),
            (MobileLocalDirectFilesSession.Failure.limitExceeded, .limitExceeded),
            (CancellationError(), nil),
        ]
        for (error, expected) in cases {
            let rpc = RPC(), session = try model(rpc)
            session.refresh(); try await finish(session, rpc, index: 0, value: object(names(0..<100), total: 101))
            session.loadNextPage(); await rpc.wait(2); let task = session.requestTask
            await rpc.reply(1, .failure(error)); await task?.value
            #expect(session.state == expected.map { .failed($0) } ?? .idle); empty(session)
            #expect(session.currentPath == "")
            #expect(await rpc.disconnects == 0)
        }
    }
    @Test(arguments: ["null", "bool", "number", "array", "object", "empty", "short", "long", "uppercase", "nonASCII", "nonHex"])
    func invalidRootMarkerMustNotBeIgnored(mode: String) throws {
        var page = object()
        let invalid: Any
        switch mode {
        case "null": invalid = NSNull()
        case "bool": invalid = true
        case "number": invalid = 12
        case "array": invalid = [] as [String]
        case "object": invalid = [:] as [String: String]
        case "empty": invalid = ""
        case "short": invalid = String(repeating: "a", count: 63)
        case "long": invalid = String(repeating: "a", count: 65)
        case "uppercase": invalid = String(repeating: "A", count: 64)
        case "nonASCII": invalid = String(repeating: "é", count: 64)
        default: invalid = String(repeating: "g", count: 64)
        }
        page["root_id"] = invalid
        do {
            _ = try MobileWorkspaceFileListResponse.decode(data(page))
            Issue.record("Present invalid root_id must fail decoding")
        } catch is DecodingError {}
    }

}
