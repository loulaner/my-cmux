import CMUXMobileCore
import CmuxMobileRPC
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectFileDownloadSessionTests {
    private static let workspace = "ab000000-0000-0000-0000-000000000001"
    private static let marker = String(repeating: "a", count: 64)
    private static let path = "dir/e\u{301}.bin"
    private static let downloadCap = CmxLocalDirectCapabilities.workspaceFilesDownload
    private static let previewCap = CmxLocalDirectCapabilities.workspaceFilesPreview
    private static let listCap = CmxLocalDirectCapabilities.workspaceFilesList
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
    private func model(_ rpc: RPC, capable: Bool = true) throws -> MobileLocalDirectFileDownloadSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9, path: Self.path,
                  rootID: Self.marker, capabilities: capable ? [Self.downloadCap] : [])
    }
    private func object(_ bytes: Data = Data("abc".utf8), path: String = Self.path) -> [String: Any] {
        ["workspace_id": Self.workspace, "path": path, "root_id": Self.marker,
         "data_base64": bytes.base64EncodedString(), "byte_count": bytes.count,
         "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func reply(_ model: MobileLocalDirectFileDownloadSession, _ rpc: RPC, _ index: Int, _ result: Result<Data, any Error>) async {
        await rpc.wait(index + 1); let task = model.requestTask
        await rpc.reply(index, result); await task?.value
    }
    private func empty(_ model: MobileLocalDirectFileDownloadSession) {
        #expect(model.data == nil && model.sha256 == nil && model.byteCount == 0)
    }
    private func preview(_ rpc: RPC, capabilities: Set<String> = [Self.previewCap, Self.downloadCap]) throws -> MobileLocalDirectFilePreviewSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9, path: Self.path,
                  rootID: Self.marker, capabilities: capabilities)
    }
    private func ready(_ parent: MobileLocalDirectFilePreviewSession, _ rpc: RPC, binary: Bool = false) async throws {
        let index = await rpc.requests.count; parent.refresh(); await rpc.wait(index + 1); let task = parent.requestTask
        var value = object(binary ? Data([255, 0]) : Data("abc".utf8)); value.removeValue(forKey: "sha256")
        value["total_bytes"] = binary ? 2 : 3; value["truncated"] = false
        await rpc.reply(index, .success(try json(value))); await task?.value
    }

    @Test func dtoTypesPathsBoundsAndCanonicalEncoding() throws {
        var invalid: [[String: Any]] = []
        for key in ["workspace_id", "path", "root_id", "data_base64", "byte_count", "sha256"] {
            var value = object(); value.removeValue(forKey: key); invalid.append(value)
            for bad: Any in [NSNull(), true, [], ["x": 1]] { value = object(); value[key] = bad; invalid.append(value) }
            if key != "byte_count" { value = object(); value[key] = 1; invalid.append(value) }
        }
        for (key, bad): (String, Any) in [("workspace_id", "bad"), ("path", ""), ("path", "/a"), ("path", "."),
            ("path", ".."), ("path", "a/../b"), ("path", "a/./b"), ("path", "a//b"), ("path", "a/"), ("path", "a\0b"),
            ("path", String(repeating: "x", count: 4097)), ("path", String(repeating: "中", count: 1366)),
            ("root_id", ""), ("root_id", String(repeating: "a", count: 63)), ("root_id", String(repeating: "a", count: 65)),
            ("root_id", String(repeating: "A", count: 64)), ("root_id", String(repeating: "g", count: 64)),
            ("root_id", String(repeating: "é", count: 32)), ("byte_count", -1), ("byte_count", 2),
            ("byte_count", "3"), ("byte_count", 1.5), ("sha256", ""), ("sha256", String(repeating: "a", count: 63)),
            ("sha256", String(repeating: "a", count: 65)), ("sha256", String(repeating: "A", count: 64)),
            ("sha256", String(repeating: "g", count: 64)), ("sha256", String(repeating: "é", count: 32))] {
            var value = object(); value[key] = bad; invalid.append(value)
        }
        for encoding in ["Zg", "Zg=", "Zh==", "Zg===", " Zg==", "Zg==\n", "Zg==!", "_w==", "-w==", String(repeating: "A", count: 2796208)] {
            var value = object(Data([102])); value["data_base64"] = encoding; invalid.append(value)
        }
        var pad = object(Data("fo".utf8)); pad["data_base64"] = "Zm9="; invalid.append(pad)
        invalid.append(object(Data(repeating: 0, count: 2097153)))
        for value in invalid { #expect(throws: DecodingError.self) { try MobileWorkspaceFileDownloadResponse.decode(json(value)) } }
        for number in ["9223372036854775808", "18446744073709551616", "1.25", "false", "null"] {
            var value = object(); value.removeValue(forKey: "byte_count")
            let prefix = String(decoding: try json(value), as: UTF8.self).dropLast()
            let raw = Data((prefix + ",\"byte_count\":" + number + "}").utf8)
            #expect(throws: DecodingError.self) { try MobileWorkspaceFileDownloadResponse.decode(raw) }
        }
        for path in ["%2e%2e/~", String(repeating: "x", count: 4096), "e\u{301}", "é"] {
            let value = try MobileWorkspaceFileDownloadResponse.decode(json(object(path: path)))
            #expect(value.path.utf8.elementsEqual(path.utf8))
        }
    }

    @Test func knownDigestsBinaryAndMaximumBytes() throws {
        for (bytes, digest) in [(Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")] {
            var value = object(bytes); value["sha256"] = digest
            let result = try MobileWorkspaceFileDownloadResponse.decode(json(value))
            #expect(result.data == bytes && result.byteCount == bytes.count && result.sha256 == digest)
        }
        for bytes in [Data([0, 255, 254, 0xC0, 0x80]), Data(repeating: 255, count: 2097152)] {
            let result = try MobileWorkspaceFileDownloadResponse.decode(json(object(bytes)))
            #expect(result.data == bytes && result.byteCount == bytes.count)
        }
        var future = object(); future["future"] = true; future["truncated"] = true; future["total_bytes"] = 100
        // Unknown metadata does not establish partial-file semantics or prove host truthfulness.
        #expect(try MobileWorkspaceFileDownloadResponse.decode(json(future)).data == Data("abc".utf8))
    }

    @Test func incorrectDigestNeverPublishesBytes() async throws {
        var value = object(); value["sha256"] = String(repeating: "0", count: 64)
        #expect(throws: DecodingError.self) { try MobileWorkspaceFileDownloadResponse.decode(json(value)) }
        let rpc = RPC(), session = try model(rpc); session.refresh()
        await reply(session, rpc, 0, .success(try json(value)))
        #expect(session.state == .failed(.invalidResponse)); empty(session)
    }

    @Test func constructionAndExplicitWireContract() async throws {
        let rpc = RPC(), session = try model(rpc), unsupported = try model(rpc, capable: false)
        #expect(session.state == .idle && session.filename == "e\u{301}.bin" && session.connectionGeneration == 9)
        #expect(session.workspaceID == Self.workspace && session.rootID == Self.marker && session.path == Self.path)
        unsupported.refresh(); #expect(unsupported.state == .failed(.unsupported)); empty(unsupported)
        for (workspace, path, root) in [("bad", Self.path, Self.marker), (Self.workspace, "", Self.marker),
            (Self.workspace, "/a", Self.marker), (Self.workspace, "a/../b", Self.marker),
            (Self.workspace, String(repeating: "x", count: 4097), Self.marker), (Self.workspace, Self.path, "bad")] {
            #expect(throws: MobileLocalDirectFileDownloadSession.Failure.invalidSelection) {
                try MobileLocalDirectFileDownloadSession(rpc: rpc, workspaceID: workspace, connectionGeneration: 9,
                    path: path, rootID: root, capabilities: [Self.downloadCap])
            }
        }
        #expect(await rpc.requests.isEmpty)
        var ids: Set<String> = []
        for (index, bytes) in [Data(), Data([0, 255, 254])].enumerated() {
            session.refresh(); empty(session); await rpc.wait(index + 1)
            let wire = try #require(JSONSerialization.jsonObject(with: await rpc.requests[index]) as? [String: Any])
            #expect(wire["method"] as? String == "mobile.workspace.files.download")
            #expect(wire["params"] as? [String: String] == ["workspace_id": Self.workspace, "path": Self.path, "root_id": Self.marker])
            let id = try #require(wire["id"] as? String); #expect(UUID(uuidString: id) != nil && ids.insert(id).inserted)
            var value = object(bytes); value["workspace_id"] = Self.workspace.uppercased()
            await reply(session, rpc, index, .success(try json(value)))
            #expect(session.state == .ready && session.data == bytes && session.byteCount == bytes.count)
        }
        #expect(await rpc.disconnects == 0); #expect(await rpc.subscriptions == 0)
    }

    @Test(arguments: ["workspace", "path", "root"])
    func contextMustMatch(mode: String) async throws {
        let rpc = RPC(), session = try model(rpc); session.refresh(); var value = object()
        if mode == "workspace" { value["workspace_id"] = UUID().uuidString }
        if mode == "path" { value["path"] = "dir/é.bin" }
        if mode == "root" { value["root_id"] = String(repeating: "b", count: 64) }
        await reply(session, rpc, 0, .success(try json(value)))
        #expect(session.state == .failed(.invalidResponse)); empty(session)
    }

    @Test func failuresClearDataAndNeverRetry() async throws {
        let cases: [(String, MobileLocalDirectFileDownloadSession.Failure)] = [
            ("invalid_params", .invalidSelection), ("method_not_found", .unsupported), ("capability_disabled", .unsupported),
            ("unsupported_workspace", .unsupportedWorkspace), ("file_transfer_disabled", .permissionDenied),
            ("forbidden", .permissionDenied), ("permission_denied", .permissionDenied), ("root_changed", .directoryChanged),
            ("workspace_changed", .directoryChanged), ("file_changed", .fileChanged), ("not_a_file", .notAFile),
            ("file_too_large", .tooLarge), ("file_not_found", .fileUnavailable), ("directory_not_found", .fileUnavailable),
            ("workspace_not_found", .fileUnavailable), ("workspace_unavailable", .fileUnavailable),
            ("admission_expired", .disconnected), ("connection_closed", .disconnected), ("disconnected", .disconnected),
            ("busy", .unavailable), ("timeout", .unavailable), ("unknown", .unavailable)]
        let rpc = RPC(), session = try model(rpc); var index = 0
        for (code, failure) in cases {
            session.refresh(); await reply(session, rpc, index, .success(try json(object()))); index += 1
            session.refresh(); empty(session)
            await reply(session, rpc, index, .failure(MobileShellConnectionError.rpcError(code, "SECRET /private/path"))); index += 1
            #expect(session.state == .failed(failure)); empty(session)
            #expect(await rpc.requests.count == index)
        }
        for (error, expected): (any Error, MobileLocalDirectFileDownloadSession.LoadState) in [
            (CancellationError(), .idle), (MobileShellConnectionError.rpcError("cancelled", "SECRET"), .idle),
            (MobileShellConnectionError.connectionClosed, .failed(.disconnected)),
            (MobileShellConnectionError.invalidResponse, .failed(.invalidResponse)),
            (MobileShellConnectionError.requestTimedOut, .failed(.unavailable)),
            (NSError(domain: "SECRET", code: 1), .failed(.unavailable))] {
            session.refresh(); await reply(session, rpc, index, .failure(error)); index += 1
            #expect(session.state == expected); empty(session)
        }
        session.refresh(); await reply(session, rpc, index, .success(Data("{}".utf8)))
        #expect(session.state == .failed(.invalidResponse)); empty(session)
        #expect(await rpc.disconnects == 0)
    }

    @Test func lateRPCAndPermanentInvalidation() async throws {
        let rpc = RPC(), session = try model(rpc)
        session.refresh(); await rpc.wait(1); let first = session.requestTask
        session.refresh(); await reply(session, rpc, 1, .success(try json(object(Data("new".utf8)))))
        await rpc.reply(0, .success(try json(object()))); await first?.value
        #expect(session.data == Data("new".utf8))
        session.refresh(); await rpc.wait(3); let stale = session.requestTask
        session.refresh(); await rpc.wait(4)
        await rpc.reply(2, .failure(MobileShellConnectionError.connectionClosed)); await stale?.value
        #expect(session.state == .loading); empty(session)
        let pending = session.requestTask; session.invalidate(); session.refresh()
        await rpc.reply(3, .success(try json(object()))); await pending?.value
        #expect(session.state == .failed(.disconnected)); empty(session)
        #expect(await rpc.requests.count == 4); #expect(await rpc.disconnects == 0)
    }

    private actor DecoderGate {
        private var count = 0
        private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func decode(_ data: Data) async throws -> MobileWorkspaceFileDownloadResponse {
            let result = try MobileWorkspaceFileDownloadResponse.decode(data)
            let index = count; count += 1
            await withCheckedContinuation { pending[index] = $0
                let ready = waiters.filter { count >= $0.0 }; waiters.removeAll { count >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
            return result // Intentionally ignores cancellation after real validation.
        }
        func wait(_ n: Int) async {
            if count >= n { return }
            await withCheckedContinuation { waiters.append((n, $0)) }
        }
        func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    }

    @Test(arguments: [false, true])
    func decodedLateResultCannotPublish(invalidate: Bool) async throws {
        let rpc = RPC(), gate = DecoderGate()
        let session = try MobileLocalDirectFileDownloadSession(rpc: rpc, workspaceID: Self.workspace,
            connectionGeneration: 9, path: Self.path, rootID: Self.marker, capabilities: [Self.downloadCap],
            decode: { try await gate.decode($0) })
        session.refresh(); await rpc.wait(1); let old = session.requestTask
        await rpc.reply(0, .success(try json(object()))); await gate.wait(1)
        if invalidate { session.invalidate() }
        else {
            session.refresh(); await rpc.wait(2); let newer = session.requestTask
            await rpc.reply(1, .success(try json(object(Data("new".utf8))))); await gate.wait(2)
            await gate.release(1); await newer?.value
        }
        await gate.release(0); await old?.value
        if invalidate { #expect(session.state == .failed(.disconnected)); empty(session) }
        else { #expect(session.state == .ready && session.data == Data("new".utf8)) }
    }

    @Test func realDecoderHonorsPreCancellation() async {
        let decoder = MobileWorkspaceFileDownloadDecoder()
        let (barrier, release) = AsyncStream<Void>.makeStream()
        let task = Task {
            var iterator = barrier.makeAsyncIterator(); _ = await iterator.next()
            do { _ = try await decoder.decode(Data("{}".utf8)); Issue.record("Cancelled decode accepted") }
            catch is CancellationError {} catch { Issue.record("Cancellation must precede invalid JSON") }
        }
        task.cancel(); release.yield(()); release.finish(); await task.value
    }

}

extension MobileLocalDirectFileDownloadSessionTests {
    @Test(arguments: ["text", "binary", "unsupported", "idle", "loading", "no-cap", "invalid_params",
                      "permission_denied", "workspace_changed", "file_changed", "file_not_found",
                      "unsupported_workspace", "unavailable", "disconnected"])
    func previewEligibility(mode: String) async throws {
        let rpc = RPC()
        let parent = try preview(rpc, capabilities: mode == "unsupported" ? [Self.downloadCap] : mode == "no-cap" ? [Self.previewCap] : [Self.previewCap, Self.downloadCap])
        if mode == "text" || mode == "no-cap" || mode == "binary" { try await ready(parent, rpc, binary: mode == "binary") }
        else if mode == "unsupported" { parent.refresh(); #expect(parent.state == .failed(.unsupported)) }
        else if mode != "idle" {
            parent.refresh(); await rpc.wait(1)
            if mode != "loading" {
                let task = parent.requestTask
                await rpc.reply(0, .failure(MobileShellConnectionError.rpcError(mode, "SECRET"))); await task?.value
            }
        }
        let allowed = ["text", "binary", "unsupported"].contains(mode)
        let count = await rpc.requests.count
        #expect(parent.canDownload == allowed && parent.startDownload() == allowed)
        if allowed {
            let child = try #require(parent.downloadSession)
            #expect(!parent.canDownload && !parent.startDownload())
            await reply(child, rpc, count, .success(try json(object(Data([0, 255])))))
            #expect(child.state == .ready && child.data == Data([0, 255]) && parent.canDownload)
            parent.closeDownload(); #expect(child.data == nil && parent.downloadSession == nil)
        } else { #expect(parent.downloadSession == nil); #expect(await rpc.requests.count == count) }
        if mode == "loading" {
            let task = parent.requestTask; await rpc.reply(0, .failure(CancellationError())); await task?.value
        }
        #expect(await rpc.disconnects == 0)
    }

    @Test(arguments: ["ready-close", "ready-refresh", "ready-invalidate", "pending-close", "pending-refresh", "pending-invalidate"])
    func previewRetiresOwnedDownloads(mode: String) async throws {
        let rpc = RPC(), parent = try preview(rpc); try await ready(parent, rpc)
        #expect(parent.startDownload()); let child = try #require(parent.downloadSession)
        await rpc.wait(2); let pending = child.requestTask
        if mode.hasPrefix("ready") { await rpc.reply(1, .success(try json(object()))); await pending?.value; #expect(child.data != nil) }
        if mode.hasSuffix("close") { parent.closeDownload(); #expect(parent.text == "abc" && parent.state == .ready) }
        else if mode.hasSuffix("refresh") { parent.refresh(); #expect(parent.text == nil && parent.state == .loading) }
        else { parent.invalidate(); #expect(parent.state == .failed(.disconnected)) }
        if mode.hasPrefix("pending") { await rpc.reply(1, .success(try json(object()))); await pending?.value }
        #expect(parent.downloadSession == nil && child.state == .failed(.disconnected)); empty(child)
        child.refresh()
        if mode.hasSuffix("refresh") {
            await rpc.wait(3); let task = parent.requestTask
            await rpc.reply(2, .failure(CancellationError())); await task?.value
        }
        #expect(await rpc.requests.count == (mode.hasSuffix("refresh") ? 3 : 2))
        #expect(await rpc.disconnects == 0)
    }

    @Test(arguments: ["busy", "file_too_large", "root_changed", "connection_closed"])
    func childFailureRetryPolicy(code: String) async throws {
        let rpc = RPC(), parent = try preview(rpc); try await ready(parent, rpc)
        #expect(parent.startDownload()); let old = try #require(parent.downloadSession)
        await reply(old, rpc, 1, .failure(MobileShellConnectionError.rpcError(code, "SECRET")))
        let retry = ["busy", "file_too_large"].contains(code)
        #expect(parent.canDownload == retry && parent.startDownload() == retry)
        if retry {
            let child = try #require(parent.downloadSession)
            #expect(child !== old && old.state == .failed(.disconnected))
            await reply(child, rpc, 2, .success(try json(object())))
            let ids = try await rpc.requests.map { try #require((JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? String) }
            #expect(Set(ids).count == ids.count)
        } else { #expect(parent.downloadSession === old); #expect(await rpc.requests.count == 2) }
        #expect(parent.text == "abc")
    }

    private func page(_ names: [String] = ["file"], path: String = "", offset: Int = 0, total: Int? = nil, root: String? = Self.marker) -> [String: Any] {
        let total = total ?? offset + names.count, end = offset + names.count
        var value: [String: Any] = ["workspace_id": Self.workspace, "path": path,
            "parent_path": path.isEmpty ? NSNull() : path.split(separator: "/").dropLast().joined(separator: "/") as Any,
            "entries": names.map { ["name": $0, "path": path.isEmpty ? $0 : path + "/" + $0, "kind": "file", "size": 3] },
            "offset": offset, "limit": 100, "total_count": total, "next_offset": end < total ? end as Any : NSNull()]
        if let root { value["root_id"] = root }
        return value
    }
    private func listReply(_ parent: MobileLocalDirectFilesSession, _ rpc: RPC, _ index: Int, _ value: [String: Any]) async throws {
        await rpc.wait(index + 1); let task = parent.requestTask
        await rpc.reply(index, .success(try json(value))); await task?.value
    }

    @Test(arguments: ["none", "preview", "download", "both", "legacy", "no-list"])
    func filesCapabilitiesAndDownloadOnlyContext(mode: String) async throws {
        var capabilities: Set<String> = mode == "no-list" ? [] : [Self.listCap]
        if ["preview", "both", "legacy"].contains(mode) { capabilities.insert(Self.previewCap) }
        if ["download", "both", "legacy", "no-list"].contains(mode) { capabilities.insert(Self.downloadCap) }
        let rpc = RPC()
        let files = try MobileLocalDirectFilesSession(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9, capabilities: capabilities)
        #expect(!files.canOpenFiles && !files.openFile(path: "file")); files.refresh()
        if mode != "no-list" { try await listReply(files, rpc, 0, page(root: mode == "legacy" ? nil : Self.marker)) }
        let allowed = ["preview", "download", "both"].contains(mode)
        #expect(files.canOpenFiles == allowed && files.openFile(path: "file") == allowed)
        #expect(files.canPreviewFiles == ["preview", "both"].contains(mode))
        #expect(await rpc.requests.count == (mode == "no-list" ? 0 : 1))
        if allowed {
            let context = try #require(files.previewSession)
            #expect(context.state == .idle && context.downloadSession == nil)
            if mode == "download" {
                context.refresh(); #expect(context.state == .failed(.unsupported) && context.canDownload)
                #expect(await rpc.requests.count == 1)
                #expect(context.startDownload()); let child = try #require(context.downloadSession)
                await reply(child, rpc, 1, .success(try json(object(path: "file"))))
                #expect(child.state == .ready && child.filename == "file")
                context.closeDownload()
                #expect(files.entries.count == 1 && files.rootID == Self.marker && files.state == .ready)
            }
        }
        #expect(await rpc.disconnects == 0)
    }

    @Test(arguments: ["refresh", "directory", "parent", "next", "invalid", "invalidate", "replace", "close", "error"])
    func filesActionsRetireWholeChildChain(mode: String) async throws {
        let rpc = RPC()
        let files = try MobileLocalDirectFilesSession(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9,
            capabilities: [Self.listCap, Self.downloadCap])
        let names = (0..<99).map { String(format: "f%05d", $0) }
        var first = page(["dir"] + names, total: 101)
        var entries = try #require(first["entries"] as? [[String: Any]])
        entries[0]["kind"] = "directory"; entries[0]["size"] = NSNull(); first["entries"] = entries
        files.refresh(); try await listReply(files, rpc, 0, first)
        var selection = names[0]
        if mode == "parent" {
            files.openDirectory(path: "dir"); try await listReply(files, rpc, 1, page(path: "dir")); selection = "dir/file"
        }
        #expect(files.openFile(path: selection)); let context = try #require(files.previewSession)
        context.refresh(); #expect(context.startDownload()); let child = try #require(context.downloadSession)
        let index = mode == "parent" ? 2 : 1
        await rpc.wait(index + 1); let pending = child.requestTask
        switch mode {
        case "directory": files.openDirectory(path: "dir")
        case "parent": files.goToParent()
        case "next": files.loadNextPage()
        case "invalid": files.openDirectory(path: "unknown")
        case "invalidate": files.invalidate()
        case "replace": #expect(files.openFile(path: names[1]))
        case "close": files.closePreview()
        default: files.refresh()
        }
        await rpc.reply(index, .success(try json(object(path: selection)))); await pending?.value
        #expect(context.state == .failed(.disconnected) && context.downloadSession == nil)
        #expect(child.state == .failed(.disconnected)); empty(child)
        if ["refresh", "directory", "parent", "next", "error"].contains(mode) {
            await rpc.wait(index + 2)
            if mode == "error" {
                let task = files.requestTask; await rpc.reply(index + 1, .failure(MobileShellConnectionError.connectionClosed)); await task?.value
                #expect(files.state == .failed(.disconnected))
            } else {
                let response = mode == "next" ? page(["f00099"], offset: 100, total: 101) : page(path: files.currentPath)
                try await listReply(files, rpc, index + 1, response)
                #expect(files.state == .ready && files.rootID == Self.marker)
            }
        }
        #expect(await rpc.disconnects == 0)
    }
}
