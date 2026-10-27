import CMUXMobileCore
import CmuxMobileRPC
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectPhotoImportTests {
    private static let workspace = "ab000000-0000-0000-0000-000000000001"
    private static let marker = String(repeating: "a", count: 64)
    private static let bytes = Data("abc".utf8)
    private let caps: Set<String> = [CmxLocalDirectCapabilities.workspaceFilesList,
        CmxLocalDirectCapabilities.workspaceFilesUpload, CmxLocalDirectCapabilities.workspaceFilesPreview]

    private actor RPC: MobileSyncing {
        var requests: [Data] = []
        var disconnects = 0
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
        func reply(_ index: Int, _ data: Data) { pending.removeValue(forKey: index)?.resume(returning: data) }
        func disconnect() { disconnects += 1 }
        func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> { AsyncStream { $0.finish() } }
    }
    private actor ReaderGate {
        var calls = 0
        var arrival: [CheckedContinuation<Void, Never>] = []
        var continuation: CheckedContinuation<MobileLocalDirectFileImportReader.Selection, any Error>?
        func read(_ url: URL) async throws -> MobileLocalDirectFileImportReader.Selection {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let ready = arrival; arrival.removeAll(); for waiter in ready { waiter.resume() }
            }
        }
        func wait() async { if calls == 0 { await withCheckedContinuation { arrival.append($0) } } }
        func finish(_ result: Result<MobileLocalDirectFileImportReader.Selection, any Error>) {
            continuation?.resume(with: result); continuation = nil
        }
    }
    private func fixture() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        try #require(!base.isEmpty && base.hasPrefix("/"))
        let root = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("direct-photo-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        print("owned import fixture: \(root.path)")
        return root
    }
    private func files(_ rpc: RPC, capabilities: Set<String>? = nil) throws -> MobileLocalDirectFilesSession {
        try .init(rpc: rpc, workspaceID: Self.workspace, connectionGeneration: 17, capabilities: capabilities ?? caps)
    }
    private func page(_ path: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["workspace_id": Self.workspace, "path": path,
            "parent_path": path.isEmpty ? NSNull() : "" as Any, "root_id": Self.marker,
            "entries": ["B", "file"].map { ["name": $0, "path": path.isEmpty ? $0 : path + "/" + $0,
                "kind": $0 == "B" ? "directory" : "file", "size": $0 == "B" ? NSNull() : 3 as Any] },
            "offset": 0, "limit": 100, "total_count": 2, "next_offset": NSNull()])
    }
    private func listReply(_ files: MobileLocalDirectFilesSession, _ rpc: RPC, index: Int, path: String = "") async throws {
        await rpc.wait(index + 1); let task = files.requestTask
        await rpc.reply(index, try page(path)); await task?.value
        #expect(files.state == .ready)
    }
    private func ready(_ files: MobileLocalDirectFilesSession, _ rpc: RPC) async throws {
        files.refresh(); try await listReply(files, rpc, index: 0)
    }
    private func selection(_ files: MobileLocalDirectFilesSession, _ gate: ReaderGate) -> MobileLocalDirectFileImportSession {
        .init(files: files, read: { try await gate.read($0) }, source: .photo)
    }
    private func picked() -> MobileLocalDirectFileImportReader.Selection { .init(fileName: "upload", data: Self.bytes) }
    private nonisolated var syntheticURL: URL { URL(fileURLWithPath: "/unused-selection-not-read-by-seam") }

    @Test(arguments: [0, 3, 256, 2_097_152]) func actualCoordinatedReads(_ size: Int) async throws {
        let root = try fixture(), url = root.appendingPathComponent("file")
        let bytes = size == 3 ? Self.bytes : Data((0..<size).map { UInt8($0 % 256) })
        try bytes.write(to: url)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
                let result = try await MobileLocalDirectPhotoTransfer.importFile(url).selection
        #expect(result.fileName == "file" && result.data == bytes)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
    }
    @Test func oversizedFileRejectedBeforeReturningBytes() async throws {
        let root = try fixture(), url = root.appendingPathComponent("oversize")
        let bytes = Data(repeating: 165, count: MobileLocalDirectFileImportReader.maximumByteCount + 1)
        try bytes.write(to: url)
        do {
            let result = try await MobileLocalDirectPhotoTransfer.importFile(url).selection
            #expect(result.data == bytes)
            #expect(result.data.count <= MobileLocalDirectFileImportReader.maximumByteCount)
            Issue.record("Oversized selection returned full data instead of tooLarge")
        } catch {
            #expect(error as? MobileLocalDirectFileImportReader.Failure == .tooLarge)
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["oversize"])
    }
    @Test(arguments: ["directory", "symlink", "fifo", "missing", "name", "control", "long", "nul", "nonfile"])
    func rejectedSourcesDoNotChangeVictim(_ kind: String) async throws {
        let root = try fixture(), victim = root.appendingPathComponent("victim")
        try Self.bytes.write(to: victim)
        var url = root.appendingPathComponent("source")
        let expected: MobileLocalDirectFileImportReader.Failure
        switch kind {
        case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); expected = .notAFile
        case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim); expected = .notAFile
        case "fifo": #expect(mkfifo(url.path, 0o600) == 0); expected = .notAFile
        case "name": url = root.appendingPathComponent("bad\\name"); try Self.bytes.write(to: url); expected = .invalidName
        case "control": url = root.appendingPathComponent("bad\nname"); try Self.bytes.write(to: url); expected = .invalidName
        case "long": url = root.appendingPathComponent(String(repeating: "x", count: 256)); expected = .invalidName
        case "nul": url = try #require(URL(string: root.absoluteString + "/bad%00name")); expected = .unavailable
        case "nonfile": url = try #require(URL(string: "https://example.invalid/file")); expected = .unavailable
        default: expected = .unavailable
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do { _ = try await MobileLocalDirectPhotoTransfer.importFile(url).selection; Issue.record("Rejected source was accepted") }
        catch { #expect(error as? MobileLocalDirectFileImportReader.Failure == expected) }
        #expect(try Data(contentsOf: victim) == Self.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
    }
    @Test func rootControlsAreNotFilenameAndCancelledReadIsQuiet() async throws {
        let root = try fixture(), directory = root.appendingPathComponent("root\n")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("source"); try Self.bytes.write(to: url)
                #expect(try await MobileLocalDirectPhotoTransfer.importFile(url).selection.fileName == "source")
        let gate = ReaderGate()
        let task = Task {
            _ = try? await gate.read(url)
            do { _ = try await MobileLocalDirectPhotoTransfer.importFile(url).selection; return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        await gate.wait(); task.cancel(); await gate.finish(.success(picked()))
        #expect(await task.value)
        #expect(try Data(contentsOf: url) == Self.bytes)
    }
    @Test func constructionNoReadAndInvalidParents() async throws {
        let rpc = RPC(), parent = try files(rpc), gate = ReaderGate()
        let idle = selection(parent, gate)
        #expect(idle.state == .failed(.unavailable) && !idle.isPickerPresented)
        idle.select(url: syntheticURL)
        #expect(await gate.calls == 0); #expect(await rpc.requests.isEmpty)
        try await ready(parent, rpc)
        let valid = selection(parent, gate)
        #expect(valid.state == .choosing && valid.isPickerPresented && valid.requestTask == nil)
        #expect(valid.directoryRevision == parent.directoryRevision && valid.path == "")
        #expect(await gate.calls == 0)
        #expect(parent.openFile(path: "file"))
        let preview = parent.previewSession
        let blocked = selection(parent, gate)
        #expect(blocked.state == .failed(.unavailable) && !blocked.isPickerPresented)
        #expect(parent.previewSession === preview)
        parent.closePreview()
        #expect(parent.prepareUpload(fileName: "other", data: Data(), directoryRevision: parent.directoryRevision))
        let other = parent.uploadSession
        #expect(selection(parent, gate).state == .failed(.unavailable))
        valid.cancel(); valid.invalidate()
        #expect(parent.uploadSession === other)
        #expect(await gate.calls == 0)
        #expect(await rpc.requests.count == 1); #expect(await rpc.disconnects == 0)
    }
    @Test func successfulSelectionOnlyPreparesThenExplicitUpload() async throws {
        let rpc = RPC(), parent = try files(rpc), gate = ReaderGate()
        try await ready(parent, rpc)
        let model = selection(parent, gate)
        model.isPickerPresented = false
        #expect(model.state == .choosing && !model.isBusy)
        model.select(load: { try await gate.read(self.syntheticURL) }); model.select(load: { try await gate.read(self.syntheticURL) })
        await gate.wait(); #expect(model.state == .reading && model.isBusy && !model.isPickerPresented)
        let task = model.requestTask
        await gate.finish(.success(picked())); await task?.value
        let child = try #require(parent.uploadSession)
        #expect(model.state == .prepared && child.state == .idle && child.sourceByteCount == 3)
        #expect(child.fileName == "upload" && child.connectionGeneration == 17 && child.path == "")
        #expect(await rpc.requests.count == 1); #expect(await gate.calls == 1)
        model.select(url: syntheticURL); model.cancel(); model.pickerFailed()
        #expect(model.state == .prepared && parent.uploadSession === child)
        model.invalidate(); #expect(parent.uploadSession === child && child.state == .idle)
        child.start(); await rpc.wait(2); let uploadTask = child.requestTask
        let sha = SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined()
        await rpc.reply(1, try JSONSerialization.data(withJSONObject: ["workspace_id": Self.workspace, "path": "upload",
            "root_id": Self.marker, "byte_count": 3, "sha256": sha, "absolute_path": "/host/upload"]))
        await uploadTask?.value
        #expect(child.state == .succeeded)
        #expect(await rpc.requests.count == 2); #expect(await rpc.disconnects == 0)
    }
    @Test(arguments: ["cancel", "invalidate", "revision", "preview", "parent", "occupied"])
    func lateReaderCannotReplaceOwnership(_ mode: String) async throws {
        let rpc = RPC(), parent = try files(rpc), gate = ReaderGate()
        try await ready(parent, rpc)
        let model = selection(parent, gate), revision = model.directoryRevision
        model.select(load: { try await gate.read(self.syntheticURL) }); await gate.wait(); let task = model.requestTask
        switch mode {
        case "cancel": model.cancel()
        case "invalidate": model.invalidate()
        case "revision":
            parent.openDirectory(path: "B"); try await listReply(parent, rpc, index: 1, path: "B")
            parent.goToParent(); try await listReply(parent, rpc, index: 2)
            #expect(parent.currentPath == "" && parent.directoryRevision != revision)
        case "preview": #expect(parent.openFile(path: "file"))
        case "parent": parent.invalidate()
        default: #expect(parent.prepareUpload(fileName: "other", data: Data(), directoryRevision: parent.directoryRevision))
        }
        let other = parent.uploadSession, preview = parent.previewSession
        await gate.finish(.success(picked())); await task?.value
        #expect(model.state != .prepared && parent.uploadSession === other && parent.previewSession === preview)
        if mode == "revision" { #expect(model.state == .failed(.directoryChanged)) }
        if mode == "parent" { #expect(model.state == .failed(.disconnected)) }
        model.select(url: syntheticURL); model.cancel(); model.invalidate()
        #expect(parent.uploadSession === other && parent.previewSession === preview)
        #expect(await gate.calls == 1); #expect(await rpc.disconnects == 0)
    }
    @Test func safeReaderErrorsAndPickerCallbacks() async throws {
        let cases: [(any Error, MobileLocalDirectFileImportSession.LoadState)] = [
            (MobileLocalDirectFileImportReader.Failure.invalidName, .failed(.invalidName)),
            (MobileLocalDirectFileImportReader.Failure.notAFile, .failed(.notAFile)),
            (MobileLocalDirectFileImportReader.Failure.tooLarge, .failed(.tooLarge)),
            (MobileLocalDirectFileImportReader.Failure.permissionDenied, .failed(.permissionDenied)),
            (MobileLocalDirectFileImportReader.Failure.fileChanged, .failed(.fileChanged)),
            (MobileLocalDirectFileImportReader.Failure.unavailable, .failed(.unavailable)),
            (MobileLocalDirectFileImportSession.Failure.unavailable, .failed(.unavailable)),
            (CancellationError(), .cancelled), (NSError(domain: "SECRET", code: 9), .failed(.unavailable))]
        let rpc = RPC(), parent = try files(rpc)
        try await ready(parent, rpc)
        for (error, expected) in cases {
            let gate = ReaderGate(), model = selection(parent, ReaderGate())
            model.pickerFailed(); #expect(model.state == .failed(.unavailable))
            let active = selection(parent, gate)
            active.select(url: syntheticURL); await gate.wait(); let task = active.requestTask
            await gate.finish(.failure(error)); await task?.value
            #expect(active.state == expected && parent.uploadSession == nil)
            active.select(url: syntheticURL); #expect(await gate.calls == 1)
        }
        let cancelled = selection(parent, ReaderGate()); cancelled.cancel(); cancelled.select(url: syntheticURL)
        #expect(cancelled.state == .cancelled && !cancelled.isPickerPresented)
        #expect(await rpc.requests.count == 1); #expect(await rpc.disconnects == 0)
    }
    @Test func publicReaderComposition() async throws {
        let rpc = RPC(), parent = try files(rpc), root = try fixture()
        let url = root.appendingPathComponent("source"); try Self.bytes.write(to: url)
        try await ready(parent, rpc)
        let model = MobileLocalDirectFileImportSession(files: parent, reader: MobileLocalDirectFileImportReader(), source: .photo)
        model.select(load: { try await MobileLocalDirectPhotoTransfer.importFile(url).selection }); await model.requestTask?.value
        #expect(model.state == .prepared && parent.uploadSession?.state == .idle)
        #expect(parent.uploadSession?.fileName == "source" && parent.uploadSession?.sourceByteCount == 3)
        #expect(await rpc.requests.count == 1)
        #expect(try Data(contentsOf: url) == Self.bytes)
    }

    @Test func dismissedPickerCanBeReplacedWithoutLoadingOldCallback() async throws {
        let rpc = RPC(), parent = try files(rpc), oldGate = ReaderGate(), newGate = ReaderGate()
        try await ready(parent, rpc)
        let old = selection(parent, oldGate)
        #expect(old.source == .photo && old.isBusy)
        old.isPickerPresented = false
        #expect(!old.isBusy && old.state == .choosing)
        #expect(await oldGate.calls == 0)
        #expect(await rpc.requests.count == 1)
        old.invalidate()
        let next = selection(parent, newGate)
        old.select(load: { try await oldGate.read(self.syntheticURL) })
        #expect(await oldGate.calls == 0)
        next.isPickerPresented = false
        next.select(load: { try await newGate.read(self.syntheticURL) })
        await newGate.wait(); let task = next.requestTask
        #expect(next.isBusy)
        await newGate.finish(.success(picked())); await task?.value
        #expect(next.state == .prepared && parent.uploadSession?.state == .idle)
        #expect(await rpc.requests.count == 1)
        parent.closeUpload()
        let fileSelection = MobileLocalDirectFileImportSession(files: parent, reader: MobileLocalDirectFileImportReader())
        #expect(fileSelection.source == .file && fileSelection.isBusy)
        fileSelection.isPickerPresented = false
        #expect(fileSelection.isBusy)
        fileSelection.cancel()
        #expect(!fileSelection.isBusy && fileSelection.state == .cancelled)
    }
}
