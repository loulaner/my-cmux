import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectFilePreviewSessionTests {
    private static let workspace = "ab000000-0000-0000-0000-000000000001"
    private static let marker = String(repeating: "a", count: 64)
    private static let path = "e\u{301}.txt"
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
    private func model(_ rpc: RPC, capable: Bool = true) throws -> MobileLocalDirectFilePreviewSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9, path: Self.path,
                  rootID: Self.marker, capabilities: capable ? [CmxLocalDirectCapabilities.workspaceFilesPreview] : [])
    }
    private func object(_ bytes: Data = Data("hello".utf8), total: Int64? = nil, truncated: Bool = false) -> [String: Any] {
        ["workspace_id": Self.workspace, "path": Self.path, "root_id": Self.marker,
         "data_base64": bytes.base64EncodedString(), "byte_count": bytes.count,
         "total_bytes": total ?? Int64(bytes.count), "truncated": truncated]
    }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func reply(_ model: MobileLocalDirectFilePreviewSession, _ rpc: RPC, _ index: Int, _ result: Result<Data, any Error>) async {
        await rpc.wait(index + 1)
        let task = model.requestTask
        await rpc.reply(index, result)
        await task?.value
    }
    private func empty(_ model: MobileLocalDirectFilePreviewSession) {
        #expect(model.text == nil && model.totalBytes == nil && model.displayedByteCount == 0 && !model.truncated)
    }

    @Test func dtoStrictFieldsAndCanonicalBase64() throws {
        var invalid: [[String: Any]] = []
        for key in ["workspace_id", "path", "root_id", "data_base64", "byte_count", "total_bytes", "truncated"] {
            var value = object(); value.removeValue(forKey: key); invalid.append(value)
            value = object(); value[key] = NSNull(); invalid.append(value)
            for bad: Any in [[], ["x": 1]] { value = object(); value[key] = bad; invalid.append(value) }
            if ["workspace_id", "path", "root_id", "data_base64"].contains(key) {
                for bad: Any in [true, 1, 1.5] { value = object(); value[key] = bad; invalid.append(value) }
            }
        }
        let fields: [(String, Any)] = [
            ("workspace_id", "invalid"), ("path", ""), ("path", "/a"), ("path", ".."), ("path", "a/./b"),
            ("path", "a//b"), ("path", "a/"), ("path", "a/../b"), ("path", "a\0b"),
            ("path", String(repeating: "x", count: 4097)), ("path", String(repeating: "中", count: 1366)),
            ("root_id", ""), ("root_id", String(repeating: "a", count: 63)), ("root_id", String(repeating: "a", count: 65)),
            ("root_id", String(repeating: "A", count: 64)), ("root_id", String(repeating: "g", count: 64)),
            ("root_id", String(repeating: "é", count: 32)), ("byte_count", true), ("total_bytes", false),
            ("byte_count", -1), ("total_bytes", -1), ("byte_count", 1.5), ("total_bytes", 1.5),
            ("byte_count", "5"), ("total_bytes", "5"), ("truncated", 1), ("truncated", "false"),
            ("byte_count", 4), ("total_bytes", 4), ("total_bytes", 6), ("truncated", true)]
        for (key, bad) in fields { var value = object(); value[key] = bad; invalid.append(value) }
        for encoded in ["Zg", "Zg=", "Zh==", "Zg==\n", " Zg==", "_w==", "-w==", "Zg==!", "Zg===", String(repeating: "A", count: 349532)] {
            var value = object(Data([102])); value["data_base64"] = encoded; invalid.append(value)
        }
        invalid.append(object(Data(repeating: 0, count: 262145)))
        for value in invalid {
            do { _ = try MobileWorkspaceFilePreviewResponse.decode(data(value)); Issue.record("Malformed preview accepted") }
            catch { #expect(error is DecodingError) }
        }
        for key in ["byte_count", "total_bytes"] {
            let raw = String(decoding: try data(object()), as: UTF8.self)
            let dict = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            for number in ["9223372036854775808", "18446744073709551616", "1.25", "true", "null"] {
                var base = dict; base.removeValue(forKey: key)
                let prefix = String(decoding: try data(base), as: UTF8.self).dropLast()
                let encoded = Data((prefix + ",\"" + key + "\":" + number + "}").utf8)
                #expect(throws: DecodingError.self) { try MobileWorkspaceFilePreviewResponse.decode(encoded) }
            }
        }
        for bytes in [Data(), Data([0, 255, 0xC3]), Data(repeating: 255, count: 262144)] {
            let dto = try MobileWorkspaceFilePreviewResponse.decode(data(object(bytes)))
            #expect(dto.data == bytes && dto.byteCount == bytes.count && dto.totalBytes == Int64(bytes.count))
        }
        var extended = object(Data(repeating: 255, count: 262144), total: Int64.max, truncated: true)
        extended["future"] = true
        #expect(try MobileWorkspaceFilePreviewResponse.decode(data(extended)).totalBytes == Int64.max)
        var literal = object(); literal["path"] = "%2e%2e/~"
        #expect(try MobileWorkspaceFilePreviewResponse.decode(data(literal)).path == "%2e%2e/~")
        literal["path"] = String(repeating: "x", count: 4096)
        literal["root_id"] = String(repeating: "0123456789abcdef", count: 4)
        #expect(try MobileWorkspaceFilePreviewResponse.decode(data(literal)).path.utf8.count == 4096)
        var badPad = object(Data("fo".utf8)); badPad["data_base64"] = "Zm9="
        #expect(throws: DecodingError.self) { try MobileWorkspaceFilePreviewResponse.decode(data(badPad)) }
    }

    @Test func constructionAndExplicitWireRequests() async throws {
        let rpc = RPC(); let preview = try model(rpc)
        #expect(await rpc.requests.isEmpty && preview.state == .idle)
        #expect(preview.workspaceID == Self.workspace && preview.connectionGeneration == 9 && preview.path == Self.path && preview.rootID == Self.marker)
        let unsupported = try model(rpc, capable: false); unsupported.refresh()
        #expect(unsupported.state == .failed(.unsupported)); empty(unsupported)
        #expect(await rpc.requests.isEmpty)
        for (workspace, path, marker) in [("bad", Self.path, Self.marker), (Self.workspace, "", Self.marker),
            (Self.workspace, "/file", Self.marker), (Self.workspace, "../file", Self.marker),
            (Self.workspace, String(repeating: "x", count: 4097), Self.marker), (Self.workspace, Self.path, "bad")] {
            #expect(throws: MobileLocalDirectFilePreviewSession.Failure.invalidSelection) {
                try MobileLocalDirectFilePreviewSession(rpc: rpc, workspaceID: workspace, connectionGeneration: 9,
                    path: path, rootID: marker, capabilities: [CmxLocalDirectCapabilities.workspaceFilesPreview])
            }
        }
        var ids: Set<String> = []
        for index in 0..<2 {
            preview.refresh(); empty(preview)
            await rpc.wait(index + 1)
            let request = try #require(JSONSerialization.jsonObject(with: await rpc.requests[index]) as? [String: Any])
            #expect(request["method"] as? String == "mobile.workspace.files.preview")
            let params = try #require(request["params"] as? [String: String])
            #expect(params == ["workspace_id": Self.workspace, "path": Self.path, "root_id": Self.marker])
            let id = try #require(request["id"] as? String); #expect(UUID(uuidString: id) != nil && ids.insert(id).inserted)
            await reply(preview, rpc, index, .success(try data(object())))
            #expect(preview.text == "hello" && preview.state == .ready && preview.displayedByteCount == 5)
        }
        #expect(await rpc.disconnects == 0)
        #expect(await rpc.subscriptions == 0)
    }

    @Test(arguments: ["workspace", "path", "root"])
    func contextMismatch(_ mode: String) async throws {
        let rpc = RPC(); let preview = try model(rpc); preview.refresh()
        var value = object()
        if mode == "workspace" { value["workspace_id"] = UUID().uuidString }
        if mode == "path" { value["path"] = "é.txt" }
        if mode == "root" { value["root_id"] = String(repeating: "b", count: 64) }
        await reply(preview, rpc, 0, .success(try data(value)))
        #expect(preview.state == .failed(.invalidResponse)); empty(preview)
    }

    @Test func plainTextAndControls() async throws {
        let rpc = RPC(); let preview = try model(rpc); var index = 0
        for text in ["", "ASCII", "中文😀", "\tline\r\n", "\u{FEFF}text\u{200D}", "<html>**plain**</html>"] {
            preview.refresh(); await reply(preview, rpc, index, .success(try data(object(Data(text.utf8))))); index += 1
            #expect(preview.text?.utf8.elementsEqual(text.utf8) == true && preview.state == .ready)
            #expect(preview.displayedByteCount == text.utf8.count && preview.totalBytes == Int64(text.utf8.count))
        }
        for scalar in Array(0...31) + Array(127...159) where ![9, 10, 13].contains(scalar) {
            let text = "before" + String(UnicodeScalar(scalar)!) + "after"
            preview.refresh(); await reply(preview, rpc, index, .success(try data(object(Data(text.utf8))))); index += 1
            #expect(preview.state == .failed(.unsupportedContent)); empty(preview)
        }
    }

    @Test func exactIncompleteUTF8Boundaries() async throws {
        let rpc = RPC(); let preview = try model(rpc); var index = 0
        let characters = ["¢", "中", "😀", "\u{0080}", "\u{07FF}", "\u{0800}", "\u{D7FF}", "\u{10000}", "\u{10FFFF}"]
        for character in characters {
            let bytes = Array(character.utf8)
            if character != "\u{0080}" {
                let body = Data(repeating: 97, count: 262144 - bytes.count) + Data(bytes)
                preview.refresh(); await reply(preview, rpc, index, .success(try data(object(body, total: 262145, truncated: true)))); index += 1
                #expect(preview.state == .ready && preview.displayedByteCount == 262144 && preview.truncated)
                #expect(preview.text?.utf8.elementsEqual(body) == true)
            }
            for length in 1..<bytes.count {
                let suffix = bytes.prefix(length)
                let body = Data(repeating: 97, count: 262144 - length) + Data(suffix)
                preview.refresh(); await reply(preview, rpc, index, .success(try data(object(body, total: 262145, truncated: true)))); index += 1
                #expect(preview.state == .ready && preview.displayedByteCount == 262144 - length)
                #expect(preview.text == String(repeating: "a", count: 262144 - length))
                #expect(preview.truncated && preview.totalBytes == 262145)
                preview.refresh(); await reply(preview, rpc, index, .success(try data(object(body)))); index += 1
                #expect(preview.state == .failed(.unsupportedContent)); empty(preview)
            }
        }
        let invalid: [[UInt8]] = [[0xFF], [0xFF, 97], [0x80], [0xC0], [0xC1, 0xBF], [0xC0, 0x80],
            [0xE0, 0x9F], [0xED, 0xA0], [0xF0, 0x8F], [0xF4, 0x90], [0xF5], [0xE0, 0x80, 0x80],
            [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xFF, 0xE4, 0xB8]]
        for suffix in invalid {
            for truncated in [false, true] {
                let body = truncated ? Data(repeating: 97, count: 262144 - suffix.count) + Data(suffix) : Data(suffix)
                preview.refresh(); await reply(preview, rpc, index, .success(try data(object(body,
                    total: truncated ? 262145 : Int64(body.count), truncated: truncated)))); index += 1
                #expect(preview.state == .failed(.unsupportedContent)); empty(preview)
            }
        }
    }

    @Test func lateRepliesCancellationAndPermanentInvalidation() async throws {
        let rpc = RPC(); let preview = try model(rpc)
        preview.refresh(); await rpc.wait(1); let old = preview.requestTask
        preview.refresh(); await reply(preview, rpc, 1, .success(try data(object(Data("new".utf8)))))
        await rpc.reply(0, .success(try data(object(Data("old".utf8))))); await old?.value
        #expect(preview.text == "new" && preview.state == .ready)
        preview.refresh(); await rpc.wait(3); let staleFailure = preview.requestTask
        preview.refresh(); await reply(preview, rpc, 3, .success(try data(object())))
        await rpc.reply(2, .failure(MobileShellConnectionError.connectionClosed)); await staleFailure?.value
        #expect(preview.text == "hello" && preview.state == .ready)
        for error: any Error in [CancellationError(), MobileShellConnectionError.rpcError("cancelled", "SECRET")] {
            let index = await rpc.requests.count; preview.refresh(); await reply(preview, rpc, index, .failure(error))
            #expect(preview.state == .idle); empty(preview)
        }
        let index = await rpc.requests.count; preview.refresh(); await rpc.wait(index + 1); let pending = preview.requestTask
        preview.invalidate(); preview.refresh()
        await rpc.reply(index, .success(try data(object()))); await pending?.value
        #expect(preview.state == .failed(.disconnected)); empty(preview)
        #expect(await rpc.requests.count == index + 1)
        #expect(await rpc.disconnects == 0)
        #expect(await rpc.subscriptions == 0)
    }

    @Test func oldReplyCannotPublishWhileReplacementPendingAndUUIDSpellingMayDiffer() async throws {
        let rpc = RPC(); let preview = try model(rpc)
        preview.refresh(); await rpc.wait(1); let old = preview.requestTask
        preview.refresh(); await rpc.wait(2)
        await rpc.reply(0, .success(try data(object()))); await old?.value
        #expect(preview.state == .loading); empty(preview)
        var value = object(); value["workspace_id"] = Self.workspace.uppercased()
        await reply(preview, rpc, 1, .success(try data(value)))
        #expect(preview.state == .ready && preview.text == "hello")
        #expect(await rpc.requests.count == 2)
    }

    @Test func safeFailuresClearPreviousContent() async throws {
        let cases: [(String, MobileLocalDirectFilePreviewSession.Failure)] = [
            ("invalid_params", .invalidSelection), ("method_not_found", .unsupported), ("capability_disabled", .unsupported),
            ("unsupported_workspace", .unsupportedWorkspace), ("file_transfer_disabled", .permissionDenied),
            ("forbidden", .permissionDenied), ("permission_denied", .permissionDenied), ("root_changed", .directoryChanged),
            ("workspace_changed", .directoryChanged), ("file_changed", .fileChanged), ("not_a_file", .unsupportedContent),
            ("file_not_found", .fileUnavailable), ("directory_not_found", .fileUnavailable), ("workspace_not_found", .fileUnavailable),
            ("workspace_unavailable", .fileUnavailable), ("admission_expired", .disconnected), ("connection_closed", .disconnected),
            ("disconnected", .disconnected), ("busy", .unavailable), ("timeout", .unavailable), ("unknown", .unavailable)]
        let rpc = RPC(); let preview = try model(rpc); var index = 0
        for (code, expected) in cases {
            preview.refresh(); await reply(preview, rpc, index, .success(try data(object()))); index += 1
            preview.refresh(); empty(preview)
            await reply(preview, rpc, index, .failure(MobileShellConnectionError.rpcError(code, "SECRET /private/path"))); index += 1
            #expect(preview.state == .failed(expected)); empty(preview)
            #expect(await rpc.requests.count == index)
        }
        for (error, expected): (any Error, MobileLocalDirectFilePreviewSession.Failure) in [
            (MobileShellConnectionError.connectionClosed, .disconnected), (MobileShellConnectionError.invalidResponse, .invalidResponse),
            (MobileShellConnectionError.requestTimedOut, .unavailable),
            (MobileShellConnectionError.transportWriteTimedOut, .unavailable),
            (NSError(domain: "SECRET", code: 1), .unavailable)] {
            preview.refresh(); await reply(preview, rpc, index, .failure(error)); index += 1
            #expect(preview.state == .failed(expected)); empty(preview)
        }
        preview.refresh(); await reply(preview, rpc, index, .success(Data("{}".utf8)))
        #expect(preview.state == .failed(.invalidResponse)); empty(preview)
        #expect(await rpc.disconnects == 0)
    }
}
