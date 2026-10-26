import CMUXMobileCore
import CmuxMobileRPC
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectFileUploadSessionTests {
    private static let workspace = "ab000000-0000-0000-0000-000000000001"
    private static let marker = String(repeating: "a", count: 64)
    private static let cap = CmxLocalDirectCapabilities.workspaceFilesUpload
    private static let bytes = Data("abc".utf8)
    private actor RPC: MobileSyncing {
        var requests: [Data] = []
        var disconnects = 0
        var subscriptions = 0
        private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func sendRequest(_ request: Data, timeoutNanoseconds: UInt64?) async throws -> Data {
            #expect(timeoutNanoseconds == nil)
            let index = requests.count; requests.append(request)
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = waiters.filter { requests.count >= $0.0 }; waiters.removeAll { requests.count >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        func wait(_ count: Int) async {
            if requests.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
        }
        func reply(_ index: Int, _ result: Result<Data, any Error>) { pending.removeValue(forKey: index)?.resume(with: result) }
        func disconnect() { disconnects += 1 }
        func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
            subscriptions += 1; return AsyncStream { $0.finish() }
        }
    }
    private actor Gate {
        var entered = false, released = false
        var arrival: [CheckedContinuation<Void, Never>] = []
        var resume: CheckedContinuation<Void, Never>?
        func pause() async {
            entered = true; let ready = arrival; arrival.removeAll(); for waiter in ready { waiter.resume() }
            if !released { await withCheckedContinuation { resume = $0 } }
        }
        func wait() async { if !entered { await withCheckedContinuation { arrival.append($0) } } }
        func open() { released = true; resume?.resume(); resume = nil }
    }
    private func model(_ rpc: RPC, path: String = "dir", name: String = "file", data: Data = Self.bytes,
                       capabilities: Set<String> = [Self.cap]) throws -> MobileLocalDirectFileUploadSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9, path: path,
                  rootID: Self.marker, fileName: name, data: data, capabilities: capabilities)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func object(_ data: Data = Self.bytes, path: String = "dir/file", root: String = "/host") -> [String: Any] {
        ["workspace_id": Self.workspace, "path": path, "root_id": Self.marker, "byte_count": data.count,
         "sha256": digest(data), "absolute_path": root + "/" + path]
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func finish(_ session: MobileLocalDirectFileUploadSession, _ rpc: RPC, index: Int = 0,
                        result: Result<Data, any Error>) async {
        await rpc.wait(index + 1); let task = session.requestTask
        await rpc.reply(index, result); await task?.value
    }
    private func empty(_ session: MobileLocalDirectFileUploadSession) {
        #expect(!session.retainsSourceData && session.uploadedFile == nil)
        #expect(session.shellQuotedPath == nil && !session.canInsertPath)
    }

    @Test func dtoSchemaBoundsAndRawBudget() throws {
        for key in ["workspace_id", "path", "root_id", "byte_count", "sha256", "absolute_path"] {
            var value = object(); value.removeValue(forKey: key)
            #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(value)) }
            for bad: Any in [NSNull(), true, [], [:]] {
                value = object(); value[key] = bad
                #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(value)) }
            }
            if key != "byte_count" {
                value = object(); value[key] = 1
                #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(value)) }
            }
        }
        let cases: [(String, [Any])] = [
            ("workspace_id", ["bad", ""]),
            ("path", ["", "/file", ".", "..", "a//b", "a/../b", "a/./b", "a/", "a\0b", "a\\b", "a\nb", String(repeating: "x", count: 256)]),
            ("root_id", ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64)]),
            ("sha256", ["", String(repeating: "B", count: 64), String(repeating: "b", count: 65), String(repeating: "é", count: 32)]),
            ("byte_count", [-1, 2_097_153, 1.5, "3"]),
            ("absolute_path", ["relative/dir/file", "/dir/file/", "/other", "/a\0/dir/file", "/" + String(repeating: "x", count: 8_193) + "/dir/file"]),
        ]
        for (key, values) in cases {
            for bad in values {
                var value = object(); value[key] = bad
                #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(value)) }
            }
        }
        for count in ["9223372036854775808", "18446744073709551616", "false", "null", "1.25"] {
            var value = object(); value.removeValue(forKey: "byte_count")
            let prefix = String(decoding: try json(value), as: UTF8.self).dropLast()
            #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(Data((prefix + ",\"byte_count\":" + count + "}").utf8)) }
        }
        var value = object(); value["metadata"] = "future"
        #expect(try MobileWorkspaceFileUploadResponse.decode(json(value)).byteCount == 3)
        let raw = try json(value), padding = Data(repeating: 32, count: 131_072 - raw.count)
        #expect(try MobileWorkspaceFileUploadResponse.decode(raw + padding).path == "dir/file")
        #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(raw + padding + Data([32])) }
        #expect(try JSONDecoder().decode(MobileWorkspaceFileUploadResponse.self, from: raw + padding + Data([32])).path == "dir/file")
    }

    @Test func dtoLiteralSuffixAndMaximumPaths() throws {
        for path in ["e\u{301}", "é", "%2e%2e/~", "a\\b/file", "a\nb/file"] {
            let receipt = try MobileWorkspaceFileUploadResponse.decode(json(object(path: path, root: "")))
            #expect(receipt.path.utf8.elementsEqual(path.utf8))
            #expect(receipt.absolutePath.utf8.elementsEqual(("/" + path).utf8))
        }
        var collision = object(path: "e\u{301}"); collision["absolute_path"] = "/host/é"
        #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(collision)) }
        let path = String(repeating: "d", count: 3_840) + "/" + String(repeating: "f", count: 255)
        let value = object(path: path, root: "/" + String(repeating: "r", count: 4_095))
        #expect(try MobileWorkspaceFileUploadResponse.decode(json(value)).absolutePath.utf8.count == 8_193)
        var tooLong = object(path: "x/" + path)
        #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(tooLong)) }
        tooLong = object(path: "e\u{301}"); tooLong["absolute_path"] = "/hoste\u{301}"
        #expect(throws: DecodingError.self) { try MobileWorkspaceFileUploadResponse.decode(json(tooLong)) }
    }

    @Test(arguments: [0, 3, 256, 2_097_152]) func codecAndOneShot(_ size: Int) async throws {
        let data = size == 3 ? Self.bytes : Data(repeating: 255, count: size)
        let rpc = RPC(), session = try model(rpc, data: data)
        #expect(session.state == .idle && session.retainsSourceData && !session.submissionStarted)
        #expect(await rpc.requests.isEmpty)
        session.start(); session.start(); await rpc.wait(1)
        #expect(session.state == .uploading && session.submissionStarted && session.requiresFolderRefresh)
        #expect(!session.retainsSourceData)
        let body = try #require(await rpc.requests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(envelope.keys) == ["id", "method", "params"])
        #expect(UUID(uuidString: envelope["id"] as? String ?? "") != nil)
        #expect(envelope["method"] as? String == "mobile.workspace.files.upload")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(Set(params.keys) == ["workspace_id", "path", "root_id", "file_name", "data_base64", "byte_count", "sha256"])
        #expect(params["workspace_id"] as? String == Self.workspace && params["path"] as? String == "dir")
        #expect(params["root_id"] as? String == Self.marker && params["file_name"] as? String == "file")
        #expect(params["data_base64"] as? String == data.base64EncodedString())
        #expect(params["byte_count"] as? Int == size && params["sha256"] as? String == digest(data))
        if size == 0 { #expect(params["sha256"] as? String == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") }
        if size == 3 { #expect(params["sha256"] as? String == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") }
        #expect(body.count <= 8_388_608)
        var acknowledgement = object(data); acknowledgement["workspace_id"] = Self.workspace.uppercased()
        await finish(session, rpc, result: .success(try json(acknowledgement)))
        #expect(session.state == .succeeded && session.uploadedFile?.byteCount == size)
        #expect(session.shellQuotedPath == "'/host/dir/file'" && session.canInsertPath && !session.requiresFolderRefresh)
        #expect(!session.retainsSourceData)
        session.start(); session.cancel()
        #expect(session.state == .succeeded && session.uploadedFile != nil)
        #expect(await rpc.requests.count == 1)
        session.invalidate(); empty(session); session.start()
        #expect(session.state == .failed(.disconnected) && session.requiresFolderRefresh)
        #expect(await rpc.requests.count == 1); #expect(await rpc.disconnects == 0); #expect(await rpc.subscriptions == 0)
    }

    @Test func constructionAndUniqueIDs() async throws {
        let rpc = RPC()
        for (path, name) in [("../x", "file"), ("/x", "file"), ("a//b", "file"), ("a\0b", "file"),
                             ("", ""), ("", "."), ("", ".."), ("", "a/b"), ("", "a\\b"), ("", "a\nb"),
                             ("", String(repeating: "é", count: 128)), (String(repeating: "d", count: 4096), "x")] {
            #expect(throws: MobileLocalDirectFileUploadSession.Failure.invalidSelection) { try model(rpc, path: path, name: name) }
        }
        #expect(throws: MobileLocalDirectFileUploadSession.Failure.tooLarge) { try model(rpc, data: Data(repeating: 0, count: 2_097_153)) }
        for (id, root) in [("bad", Self.marker), (Self.workspace, ""), (Self.workspace, String(repeating: "A", count: 64))] {
            #expect(throws: MobileLocalDirectFileUploadSession.Failure.invalidSelection) {
                try MobileLocalDirectFileUploadSession(rpc: rpc, workspaceID: id, connectionGeneration: 9,
                    path: "", rootID: root, fileName: "file", data: Data(), capabilities: [Self.cap])
            }
        }
        let unsupported = try model(rpc, capabilities: [])
        unsupported.start(); unsupported.start(); empty(unsupported)
        #expect(unsupported.state == .failed(.unsupported) && !unsupported.submissionStarted && !unsupported.requiresFolderRefresh)
        let cancelled = try model(rpc); cancelled.cancel(); cancelled.start(); cancelled.invalidate(); cancelled.start()
        #expect(cancelled.state == .failed(.disconnected)); empty(cancelled)
        #expect(await rpc.requests.isEmpty)
        var ids: [String] = []
        for index in 0..<2 {
            let session = try model(rpc); session.start(); await rpc.wait(index + 1)
            let body = await rpc.requests[index]
            let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any]); ids.append(try #require(envelope["id"] as? String))
            await finish(session, rpc, index: index, result: .success(try json(object())))
        }
        #expect(ids[0] != ids[1])
    }

    @Test func incorrectDigestNeverPublishesReceipt() async throws {
        let rpc = RPC(), session = try model(rpc)
        var value = object(); value["sha256"] = String(repeating: "b", count: 64)
        #expect(try MobileWorkspaceFileUploadResponse.decode(json(value)).sha256 == String(repeating: "b", count: 64))
        session.start(); await finish(session, rpc, result: .success(try json(value)))
        #expect(session.state == .failed(.invalidResponse))
        #expect(session.uploadedFile == nil)
        #expect(session.shellQuotedPath == nil)
    }

    @Test(arguments: ["workspace_id", "path", "root_id", "byte_count"]) func mismatchedAcknowledgement(_ field: String) async throws {
        let rpc = RPC(), session = try model(rpc)
        var value = object()
        switch field {
        case "workspace_id": value[field] = UUID().uuidString
        case "path": value[field] = "dir/other"; value["absolute_path"] = "/host/dir/other"
        case "root_id": value[field] = String(repeating: "c", count: 64)
        default: value[field] = 0
        }
        session.start(); await finish(session, rpc, result: .success(try json(value)))
        #expect(session.state == .failed(.invalidResponse) && session.requiresFolderRefresh); empty(session)
        session.start(); #expect(await rpc.requests.count == 1)
    }

    @Test func safeFailuresAndCancellation() async throws {
        typealias Failure = MobileLocalDirectFileUploadSession.Failure
        let mappings: [(String, Failure)] = [("invalid_params", .invalidSelection), ("method_not_found", .unsupported),
            ("capability_disabled", .unsupported), ("unsupported_workspace", .unsupportedWorkspace),
            ("file_transfer_disabled", .permissionDenied), ("forbidden", .permissionDenied), ("permission_denied", .permissionDenied),
            ("workspace_not_found", .directoryUnavailable), ("workspace_unavailable", .directoryUnavailable), ("directory_not_found", .directoryUnavailable),
            ("root_changed", .directoryChanged), ("workspace_changed", .directoryChanged), ("file_changed", .fileChanged),
            ("file_already_exists", .alreadyExists), ("file_too_large", .tooLarge), ("integrity_mismatch", .integrityMismatch),
            ("not_a_directory", .notDirectory), ("admission_expired", .disconnected), ("connection_closed", .disconnected),
            ("disconnected", .disconnected), ("busy", .unavailable), ("timeout", .unavailable), ("SECRET", .unavailable)]
        for (code, expected) in mappings {
            let rpc = RPC(), session = try model(rpc); session.start()
            await finish(session, rpc, result: .failure(MobileShellConnectionError.rpcError(code, "SECRET /host/path")))
            #expect(session.state == .failed(expected)); #expect(!String(describing: session.state).contains("SECRET"))
            empty(session); #expect(session.submissionStarted && session.requiresFolderRefresh)
            session.start(); #expect(await rpc.requests.count == 1); #expect(await rpc.disconnects == 0)
        }
        for error: any Error in [CancellationError(), MobileShellConnectionError.rpcError("cancelled", "SECRET")] {
            let rpc = RPC(), session = try model(rpc); session.start(); await finish(session, rpc, result: .failure(error))
            #expect(session.state == .cancelled && session.requiresFolderRefresh); empty(session); session.start()
            #expect(await rpc.requests.count == 1)
        }
        for (error, expected): (any Error, Failure) in [(MobileShellConnectionError.connectionClosed, .disconnected),
            (MobileShellConnectionError.invalidResponse, .invalidResponse), (MobileShellConnectionError.requestTimedOut, .unavailable),
            (MobileShellConnectionError.transportWriteTimedOut, .unavailable), (MobileShellConnectionError.rpcError(nil, "SECRET"), .unavailable),
            (NSError(domain: "SECRET", code: 1), .unavailable)] {
            let rpc = RPC(), session = try model(rpc); session.start(); await finish(session, rpc, result: .failure(error))
            #expect(session.state == .failed(expected)); empty(session)
        }
        let rpc = RPC(), session = try model(rpc); session.start()
        await finish(session, rpc, result: .success(Data("not JSON".utf8)))
        #expect(session.state == .failed(.invalidResponse)); empty(session)
    }

    @Test(arguments: ["prepare", "rpc", "decode"], [false, true])
    func lateCompletion(_ phase: String, _ invalidate: Bool) async throws {
        let rpc = RPC(), codec = MobileWorkspaceFileUploadCodec(), gate = Gate()
        let session = try MobileLocalDirectFileUploadSession(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9,
            path: "dir", rootID: Self.marker, fileName: "file", data: Self.bytes, capabilities: [Self.cap],
            prepare: { input in let value = try await codec.prepare(input); if phase == "prepare" { await gate.pause() }; return value },
            decode: { data in let value = try await codec.decode(data); if phase == "decode" { await gate.pause() }; return value })
        session.start(); let task = session.requestTask
        if phase == "prepare" { await gate.wait() }
        else {
            await rpc.wait(1)
            if phase == "decode" { await rpc.reply(0, .success(try json(object()))); await gate.wait() }
        }
        if invalidate { session.invalidate() } else { session.cancel() }
        empty(session)
        #expect(session.submissionStarted == (phase != "prepare"))
        #expect(session.requiresFolderRefresh == (phase != "prepare"))
        if phase == "rpc" { await rpc.reply(0, .success(try json(object()))) } else { await gate.open() }
        await task?.value; empty(session)
        #expect(session.state == (invalidate ? .failed(.disconnected) : .cancelled))
        session.start(); #expect(await rpc.requests.count == (phase == "prepare" ? 0 : 1))
        #expect(await rpc.disconnects == 0)
    }

    @Test func quotingAndOpaqueRootControls() async throws {
        for (root, expected): (String, String?) in [("/space dir/'$(x)`x`;", "'/space dir/'\\''$(x)`x`;/dir/file'"),
            ("", "'/dir/file'"), ("/host\nunsafe", nil), ("/host\runsafe", nil), ("/host\u{7f}unsafe", nil)] {
            let rpc = RPC(), session = try model(rpc); session.start()
            await finish(session, rpc, result: .success(try json(object(root: root))))
            #expect(session.state == .succeeded && session.uploadedFile != nil)
            #expect(session.shellQuotedPath == expected)
            #expect(session.canInsertPath == (expected != nil))
            if let quoted = session.shellQuotedPath { #expect(!quoted.contains("\n") && !quoted.contains("\r")) }
            session.invalidate(); #expect(session.shellQuotedPath == nil)
        }
    }
}

extension MobileLocalDirectFileUploadSessionTests {
    private var allCaps: Set<String> { [Self.cap, CmxLocalDirectCapabilities.workspaceFilesList,
        CmxLocalDirectCapabilities.workspaceFilesPreview, CmxLocalDirectCapabilities.workspaceFilesDownload] }
    private func parent(_ rpc: RPC, caps: Set<String>? = nil) throws -> MobileLocalDirectFilesSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9, capabilities: caps ?? allCaps)
    }
    private func page(path: String = "", names: [String] = ["B", "file"], offset: Int = 0,
                      total: Int? = nil, marker: String? = Self.marker) throws -> Data {
        let count = total ?? offset + names.count, end = offset + names.count
        var value: [String: Any] = ["workspace_id": Self.workspace, "path": path,
            "parent_path": path.isEmpty ? NSNull() : path.split(separator: "/").dropLast().joined(separator: "/") as Any,
            "entries": names.map { ["name": $0, "path": path.isEmpty ? $0 : path + "/" + $0,
                                    "kind": $0 == "B" ? "directory" : "file", "size": $0 == "B" ? NSNull() : 3 as Any] },
            "offset": offset, "limit": 100, "total_count": count, "next_offset": end < count ? end as Any : NSNull()]
        if let marker { value["root_id"] = marker }
        return try json(value)
    }
    private func listReply(_ parent: MobileLocalDirectFilesSession, _ rpc: RPC, index: Int,
                           value: Result<Data, any Error>) async {
        await rpc.wait(index + 1); let task = parent.requestTask
        await rpc.reply(index, value); await task?.value
    }
    private func ready(_ parent: MobileLocalDirectFilesSession, _ rpc: RPC, marker: String? = Self.marker,
                       paginated: Bool = false) async throws {
        let index = await rpc.requests.count; parent.refresh()
        let names = paginated ? (0..<100).map { String(format: "f%03d", $0) } : ["B", "file"]
        await listReply(parent, rpc, index: index, value: .success(try page(names: names, total: paginated ? 101 : nil, marker: marker)))
        #expect(parent.state == .ready)
    }
    @Test(arguments: [false, true], [false, true]) func capabilityOwnership(_ list: Bool, _ upload: Bool) async throws {
        let rpc = RPC()
        var caps: Set<String> = []
        if list { caps.insert(CmxLocalDirectCapabilities.workspaceFilesList) }
        if upload { caps.insert(Self.cap) }
        let folder = try parent(rpc, caps: caps)
        #expect(!folder.canUploadFiles)
        #expect(!folder.prepareUpload(fileName: "file", data: Self.bytes, directoryRevision: folder.directoryRevision))
        if list {
            try await ready(folder, rpc)
            #expect(folder.canUploadFiles == upload)
            let count = await rpc.requests.count
            #expect(folder.prepareUpload(fileName: "upload", data: Self.bytes, directoryRevision: folder.directoryRevision) == upload)
            #expect(await rpc.requests.count == count)
            if upload {
                let child = try #require(folder.uploadSession)
                #expect(child.workspaceID == Self.workspace && child.connectionGeneration == 9 && child.path == "")
                #expect(child.rootID == Self.marker && child.fileName == "upload" && child.sourceByteCount == 3)
                #expect(child.state == .idle && child.requestTask == nil && !child.submissionStarted)
                #expect(!folder.canUploadFiles)
                #expect(!folder.prepareUpload(fileName: "other", data: Data(), directoryRevision: folder.directoryRevision))
                #expect(folder.uploadSession === child)
                folder.closePreview(); #expect(folder.uploadSession === child)
                let entries = folder.entries
                folder.closeUpload(); empty(child)
                #expect(folder.entries == entries && folder.rootID == Self.marker && folder.state == .ready)
                #expect(folder.canUploadFiles && folder.uploadSession == nil)
            }
            folder.invalidate(); #expect(!folder.canUploadFiles)
        } else {
            folder.refresh(); #expect(folder.state == .failed(.unsupported))
            #expect(await rpc.requests.isEmpty)
        }
        #expect(await rpc.disconnects == 0)
    }
    @Test func legacyRevisionAndInvalidSelectionPreservePreview() async throws {
        let rpc = RPC(), folder = try parent(rpc)
        try await ready(folder, rpc, marker: nil)
        #expect(!folder.canUploadFiles)
        #expect(!folder.prepareUpload(fileName: "upload", data: Self.bytes, directoryRevision: folder.directoryRevision))
        try await ready(folder, rpc)
        #expect(folder.openFile(path: "file"))
        let preview = try #require(folder.previewSession)
        preview.refresh(); await rpc.wait(3); let previewTask = preview.requestTask
        await rpc.reply(2, .success(try json(["workspace_id": Self.workspace, "path": "file", "root_id": Self.marker,
            "data_base64": Self.bytes.base64EncodedString(), "byte_count": 3, "total_bytes": 3, "truncated": false])))
        await previewTask?.value
        #expect(preview.startDownload()); await rpc.wait(4)
        let download = try #require(preview.downloadSession), downloadTask = download.requestTask
        for name in ["", "..", "bad/name"] {
            #expect(!folder.prepareUpload(fileName: name, data: Data(), directoryRevision: folder.directoryRevision))
            #expect(folder.previewSession === preview && preview.downloadSession === download)
        }
        #expect(!folder.prepareUpload(fileName: "file", data: Data(repeating: 0, count: 2_097_153), directoryRevision: folder.directoryRevision))
        #expect(folder.previewSession === preview)
        let revision = folder.directoryRevision
        folder.openDirectory(path: "B")
        #expect(!folder.prepareUpload(fileName: "upload", data: Data(), directoryRevision: revision))
        await listReply(folder, rpc, index: 4, value: .success(try page(path: "B", names: ["file"])))
        folder.goToParent()
        await listReply(folder, rpc, index: 5, value: .success(try page()))
        await rpc.reply(3, .failure(CancellationError())); await downloadTask?.value
        #expect(folder.currentPath == "" && folder.rootID == Self.marker && folder.directoryRevision != revision)
        #expect(!folder.prepareUpload(fileName: "upload", data: Data(), directoryRevision: revision), "A→B→A rejects old picker epoch")
        #expect(folder.openFile(path: "file"))
        let newPreview = try #require(folder.previewSession)
        #expect(folder.prepareUpload(fileName: "upload", data: Data(), directoryRevision: folder.directoryRevision))
        #expect(folder.previewSession == nil && newPreview.state == .failed(.disconnected))
        #expect(download.state == .failed(.disconnected))
        #expect(await rpc.requests.count == 6)
    }
    @Test(arguments: ["directory", "parent", "page", "refresh", "clear", "invalidate", "openFile", "failure"])
    func directoryActionsRetirePendingUpload(_ mode: String) async throws {
        let rpc = RPC(), folder = try parent(rpc)
        try await ready(folder, rpc, paginated: mode == "page")
        if mode == "parent" {
            folder.openDirectory(path: "B")
            await listReply(folder, rpc, index: 1, value: .success(try page(path: "B", names: ["file"])))
        }
        #expect(folder.prepareUpload(fileName: "upload", data: Self.bytes, directoryRevision: folder.directoryRevision))
        let old = try #require(folder.uploadSession), oldIndex = await rpc.requests.count
        old.start(); await rpc.wait(oldIndex + 1); let oldTask = old.requestTask
        let next = oldIndex + 1
        switch mode {
        case "directory": folder.openDirectory(path: "B")
        case "parent": folder.goToParent()
        case "page": folder.loadNextPage()
        case "refresh", "failure": folder.refresh()
        case "clear": folder.openDirectory(path: "absent")
        case "invalidate": folder.invalidate()
        default: #expect(folder.openFile(path: "file"))
        }
        #expect(folder.uploadSession == nil && old.state == .failed(.disconnected)); empty(old)
        if ["directory", "parent", "page", "refresh", "failure"].contains(mode) {
            let result: Result<Data, any Error>
            if mode == "failure" { result = .failure(MobileShellConnectionError.rpcError("forbidden", "SECRET")) }
            else if mode == "directory" { result = .success(try page(path: "B", names: ["file"])) }
            else if mode == "page" { result = .success(try page(names: ["z"], offset: 100, total: 101)) }
            else { result = .success(try page(marker: mode == "refresh" ? String(repeating: "b", count: 64) : Self.marker)) }
            await listReply(folder, rpc, index: next, value: result)
        }
        if mode == "openFile" {
            let preview = folder.previewSession; folder.closeUpload()
            #expect(folder.previewSession === preview && preview != nil)
        }
        if folder.canUploadFiles {
            #expect(folder.prepareUpload(fileName: "new", data: Data(), directoryRevision: folder.directoryRevision))
        }
        let replacement = folder.uploadSession
        await rpc.reply(oldIndex, .success(try json(object(path: old.path.isEmpty ? "upload" : old.path + "/upload"))))
        await oldTask?.value
        #expect(folder.uploadSession === replacement && old.state == .failed(.disconnected)); empty(old)
        #expect(await rpc.disconnects == 0)
    }
    @Test func completedReceiptKeptUntilExplicitParentActionAndOldReplyCannotWin() async throws {
        let rpc = RPC(), folder = try parent(rpc)
        try await ready(folder, rpc)
        #expect(folder.prepareUpload(fileName: "file", data: Self.bytes, directoryRevision: folder.directoryRevision))
        let old = try #require(folder.uploadSession); old.start(); await rpc.wait(2); let oldTask = old.requestTask
        folder.closeUpload()
        #expect(folder.prepareUpload(fileName: "file", data: Self.bytes, directoryRevision: folder.directoryRevision))
        let current = try #require(folder.uploadSession); current.start(); await rpc.wait(3)
        await rpc.reply(1, .success(try json(object(path: "file")))); await oldTask?.value
        #expect(current.state == .uploading && folder.uploadSession === current)
        await finish(current, rpc, index: 2, result: .success(try json(object(path: "file"))))
        #expect(current.state == .succeeded && folder.uploadSession === current)
        #expect(folder.entries.map(\.name) == ["B", "file"] && folder.rootID == Self.marker)
        #expect(await rpc.requests.count == 3, "success does not refresh directory or execute terminal actions")
        #expect(current.shellQuotedPath == "'/host/file'")
        folder.refresh(); #expect(current.shellQuotedPath == nil && current.state == .failed(.disconnected))
        await listReply(folder, rpc, index: 3, value: .success(try page()))
        #expect(await rpc.disconnects == 0)
    }
    @Test(arguments: [false, true]) func preparationFailureClearsWithoutSubmission(_ cancelled: Bool) async throws {
        let rpc = RPC(), codec = MobileWorkspaceFileUploadCodec()
        let session = try MobileLocalDirectFileUploadSession(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 9,
            path: "", rootID: Self.marker, fileName: "file", data: Self.bytes, capabilities: [Self.cap],
            prepare: { _ in if cancelled { throw CancellationError() }; throw NSError(domain: "SECRET", code: 1) },
            decode: { try await codec.decode($0) })
        session.start(); await session.requestTask?.value
        #expect(session.state == (cancelled ? .cancelled : .failed(.unavailable)))
        #expect(!session.submissionStarted && !session.requiresFolderRefresh); empty(session)
        session.start(); #expect(await rpc.requests.isEmpty)
    }
}


extension MobileLocalDirectFileUploadSessionTests {
    @Test func maximumEnvelopeAndCodecCancellation() async throws {
        let codec = MobileWorkspaceFileUploadCodec()
        let path = ([String(repeating: "\u{1}", count: 240)] + Array(repeating: String(repeating: "\u{1}", count: 239), count: 15)).joined(separator: "/")
        let input = MobileWorkspaceFileUploadCodec.Input(id: UUID(), workspaceID: Self.workspace, path: path,
            rootID: Self.marker, fileName: String(repeating: "\"", count: 255), data: Data(repeating: 255, count: 2_097_152))
        let prepared = try await codec.prepare(input)
        let envelope = try #require(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(prepared.byteCount == 2_097_152 && prepared.sha256 == digest(input.data))
        #expect((params["path"] as? String)?.utf8.elementsEqual(path.utf8) == true)
        #expect(params["file_name"] as? String == input.fileName)
        let frame = try MobileSyncFrameCodec.encodeFrame(prepared.body)
        #expect(frame.count < 8_388_608)
        print("upload maximum escaped request body=\(prepared.body.count) frame=\(frame.count)")
        for decode in [false, true] {
            let gate = Gate(), receipt = try json(object())
            let task = Task {
                await gate.pause()
                do {
                    if decode { _ = try await codec.decode(receipt) }
                    else { _ = try await codec.prepare(input) }
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            await gate.wait(); task.cancel(); await gate.open()
            #expect(await task.value)
        }
    }
}
