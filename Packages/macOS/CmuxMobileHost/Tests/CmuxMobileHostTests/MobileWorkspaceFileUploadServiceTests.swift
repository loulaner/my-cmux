import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxMobileHost

@Suite(.timeLimit(.minutes(1)))
struct MobileWorkspaceFileUploadServiceTests {
    private enum Rejected: Error { case admission }
    private actor Gate {
        var calls = 0
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func count() { calls += 1 }
        func enter() async {
            calls += 1
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                let ready = waiters.filter { calls >= $0.0 }; waiters.removeAll { calls >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        func wait(_ count: Int = 1) async {
            if calls >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func release() { let all = pending; pending.removeAll(); for item in all { item.resume() } }
    }
    private func fixture() throws -> URL {
        let value = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let root = URL(fileURLWithPath: value).appendingPathComponent("workspace-upload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func marker(_ root: URL) async throws -> String { try await MobileWorkspaceFileListService(rootDirectory: root).list().rootID }
    private func names(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }
    private func stage(_ root: URL) throws -> URL {
        let stages = try names(root).filter { $0.hasPrefix(".my-cmux-upload-") }
        #expect(stages.count == 1)
        return root.appendingPathComponent(try #require(stages.first))
    }
    private func write(_ service: MobileWorkspaceFileUploadService, marker: String, directory: String = "", name: String = "file",
                       data: Data = Data("abc".utf8), gate: @Sendable () async throws -> Void = {}) async throws -> MobileWorkspaceFileUpload {
        try await service.write(relativeDirectoryPath: directory, fileName: name, data: data,
                                expectedRootID: marker, expectedSHA256: digest(data), beforeCommit: gate)
    }
    private func expect(_ expected: MobileWorkspaceFileUploadError, _ body: () async throws -> Void) async {
        do { try await body(); Issue.record("Expected safe upload rejection") }
        catch let error as MobileWorkspaceFileUploadError { #expect(error == expected) }
        catch { Issue.record("Unexpected error type") }
    }

    @Test func validationBeforeAnyDiskChangesOrGate() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("absent")
        let service = try MobileWorkspaceFileUploadService(rootDirectory: absent)
        #expect(try names(root).isEmpty) // Initialization neither opens nor creates the root.
        #expect(throws: MobileWorkspaceFileUploadError.invalidPath) { try MobileWorkspaceFileUploadService(rootDirectory: URL(string: "https://invalid.test")!) }
        let gate = Gate(), hex = String(repeating: "a", count: 64), bytes = Data("abc".utf8)
        for path in ["/a", ".", "..", "a/../b", "a//b", "a/", "a\0b", String(repeating: "x", count: 4097)] {
            await expect(.invalidPath) { _ = try await write(service, marker: hex, directory: path, gate: { await gate.count() }) }
        }
        for name in ["", ".", "..", "/a", "a/b", "a\\b", "a\0b", "a\nb", "a\tb", "a\u{7F}b", "a\u{85}b", String(repeating: "x", count: 256), String(repeating: "中", count: 86)] {
            await expect(.invalidPath) { _ = try await write(service, marker: hex, name: name, gate: { await gate.count() }) }
        }
        await expect(.invalidPath) { _ = try await write(service, marker: hex, directory: String(repeating: "x", count: 4095), name: "xx") }
        for bad in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "é", count: 32)] {
            await expect(.invalidRequest) {
                _ = try await service.write(relativeDirectoryPath: "", fileName: "file", data: bytes,
                    expectedRootID: bad, expectedSHA256: digest(bytes), beforeCommit: { await gate.count() })
            }
            await expect(.invalidRequest) {
                _ = try await service.write(relativeDirectoryPath: "", fileName: "file", data: bytes,
                    expectedRootID: hex, expectedSHA256: bad, beforeCommit: { await gate.count() })
            }
        }
        await expect(.tooLarge) { _ = try await write(service, marker: hex, data: Data(repeating: 0, count: 2_097_153), gate: { await gate.count() }) }
        await expect(.integrityMismatch) {
            _ = try await service.write(relativeDirectoryPath: "", fileName: "file", data: bytes,
                expectedRootID: hex, expectedSHA256: hex, beforeCommit: { await gate.count() })
        }
        #expect(await gate.calls == 0); #expect(try names(root).isEmpty)
    }

    @Test(arguments: [0, 3, 7, 2_097_152])
    func fullBytesPrivateModesAndGateTiming(size: Int) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = size == 3 ? Data("abc".utf8) : Data((0..<size).map { UInt8($0 % 251) })
        let service = try MobileWorkspaceFileUploadService(rootDirectory: root), id = try await marker(root), gate = Gate()
        let result = try await write(service, marker: id, data: bytes) {
            await gate.count()
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("file").path))
            let stage = try stage(root), content = stage.appendingPathComponent("content")
            #expect(try Data(contentsOf: content) == bytes)
            var directoryStat = stat(), fileStat = stat()
            #expect(lstat(stage.path, &directoryStat) == 0 && directoryStat.st_mode & 0o077 == 0)
            #expect(lstat(content.path, &fileStat) == 0 && fileStat.st_mode & 0o077 == 0 && fileStat.st_nlink == 1)
        }
        #expect(result.relativePath == "file" && result.rootID == id && result.byteCount == size && result.sha256 == digest(bytes))
        #expect(MobileWorkspaceFileUploadService.maximumUploadBytes == 2_097_152)
        if size == 0 { #expect(result.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") }
        if size == 3 { #expect(result.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") }
        #expect(try Data(contentsOf: root.appendingPathComponent("file")) == bytes)
        #expect(try names(root) == ["file"]); #expect(await gate.calls == 1)
        var metadata = stat(); #expect(lstat(root.appendingPathComponent("file").path, &metadata) == 0)
        #expect(metadata.st_mode & 0o077 == 0 && metadata.st_nlink == 1)
    }

    @Test(arguments: ["regular", "symlink", "directory"])
    func existingDestinationIsNeverReplaced(kind: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim"), file = root.appendingPathComponent("file")
        let sentinel = Data("owned sentinel".utf8); try sentinel.write(to: victim)
        if kind == "regular" { try sentinel.write(to: file) }
        else if kind == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim) }
        else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false); try sentinel.write(to: file.appendingPathComponent("inside")) }
        var before = stat(); try #require(lstat(file.path, &before) == 0)
        let service = try MobileWorkspaceFileUploadService(rootDirectory: root), id = try await marker(root), gate = Gate()
        await expect(.alreadyExists) { _ = try await write(service, marker: id, gate: { await gate.count() }) }
        var after = stat(); #expect(lstat(file.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode)
        #expect(try Data(contentsOf: victim) == sentinel)
        if kind != "directory" { #expect(try Data(contentsOf: file) == sentinel) }
        else { #expect(try Data(contentsOf: file.appendingPathComponent("inside")) == sentinel) }
        #expect(try names(root) == ["file", "victim"]); #expect(await gate.calls == 1)
    }

    @Test func literalUnicodeNamesAndDirectoryFailures() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileUploadService(rootDirectory: root), id = try await marker(root)
        for (index, component) in ["%2e%2e", "~", "中文", "e\u{301}"].enumerated() {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(component), withIntermediateDirectories: false)
            let name = index == 0 ? String(repeating: "x", count: 255) : ".合法%~"
            let result = try await write(service, marker: id, directory: component, name: name)
            #expect(result.relativePath.utf8.elementsEqual((component + "/" + name).utf8))
            #expect(try Data(contentsOf: root.appendingPathComponent(result.relativePath)) == Data("abc".utf8))
        }
        let victim = root.appendingPathComponent("victim"); try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        try Data("sentinel".utf8).write(to: victim.appendingPathComponent("file"))
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        await expect(.notFound) { _ = try await write(service, marker: id, directory: "missing") }
        await expect(.notDirectory) { _ = try await write(service, marker: id, directory: "link") }
        let linkedRoot = try MobileWorkspaceFileUploadService(rootDirectory: link)
        await expect(.notDirectory) { _ = try await write(linkedRoot, marker: id) }
        await expect(.rootChanged) { _ = try await write(service, marker: String(repeating: "b", count: 64)) }
        #expect(try Data(contentsOf: victim.appendingPathComponent("file")) == Data("sentinel".utf8))
        #expect(try names(root).allSatisfy { !$0.hasPrefix(".my-cmux-upload-") })
    }

    @Test(arguments: ["reject", "throwCancel", "insideCancel", "preCancel"])
    func admissionAndCancellationCleanUnpublishedContent(mode: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileUploadService(rootDirectory: root), id = try await marker(root), gate = Gate()
        let task = Task {
            if mode == "preCancel" { await gate.enter() }
            return try await write(service, marker: id) {
                if mode == "reject" { throw Rejected.admission }
                if mode == "throwCancel" { throw CancellationError() }
                await gate.enter()
            }
        }
        if mode == "insideCancel" || mode == "preCancel" { await gate.wait(); task.cancel(); await gate.release() }
        do { _ = try await task.value; Issue.record("Expected gate/cancel rejection") }
        catch Rejected.admission { #expect(mode == "reject") }
        catch is CancellationError { #expect(mode != "reject") }
        #expect(try names(root).isEmpty)
        if mode == "preCancel" { #expect(await gate.calls == 1) }
    }

    @Test(arguments: ["directory", "root", "stageLink", "stageDirectory", "contentLink", "contentReplace", "sameInode", "sameSize", "hardLink"])
    func observableGateWindowChangesRejectPublication(mode: String) async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let victim = outside.appendingPathComponent("content"), sentinel = Data("protected outside sentinel".utf8); try sentinel.write(to: victim)
        let service = try MobileWorkspaceFileUploadService(rootDirectory: root), id = try await marker(root)
        await expect(mode == "root" ? .rootChanged : .fileChanged) {
            _ = try await write(service, marker: id, directory: "target") {
                let stage = try stage(target), content = stage.appendingPathComponent("content")
                switch mode {
                case "directory":
                    try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("oldTarget"))
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                case "root":
                    try FileManager.default.moveItem(at: root, to: base.appendingPathComponent("oldRoot"))
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                case "stageLink", "stageDirectory":
                    try FileManager.default.moveItem(at: stage, to: target.appendingPathComponent("movedStage"))
                    if mode == "stageLink" { try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: outside) }
                    else { try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false) }
                case "contentLink", "contentReplace":
                    try FileManager.default.moveItem(at: content, to: stage.appendingPathComponent("original"))
                    if mode == "contentLink" { try FileManager.default.createSymbolicLink(at: content, withDestinationURL: victim) }
                    else { try sentinel.write(to: content) }
                case "sameInode", "sameSize":
                    let fd = open(content.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    try #require(fd >= 0); defer { close(fd) }
                    if mode == "sameInode" { try #require(ftruncate(fd, 0) == 0) }
                    else {
                        let replacement = Data("xyz".utf8)
                        let count = replacement.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                        try #require(count == 3)
                        var metadata = stat(); try #require(fstat(fd, &metadata) == 0)
                        var times = [metadata.st_atimespec, timespec(tv_sec: metadata.st_mtimespec.tv_sec + 1, tv_nsec: 0)]
                        try #require(futimens(fd, &times) == 0)
                    }
                default: try FileManager.default.linkItem(at: content, to: stage.appendingPathComponent("hardlink"))
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("file").path))
        #expect(try Data(contentsOf: victim) == sentinel)
        if mode == "directory" { #expect(try names(root.appendingPathComponent("oldTarget")).isEmpty) }
        if mode == "root" { #expect(try names(base.appendingPathComponent("oldRoot/target")).isEmpty) }
        if mode == "stageLink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: stage(target).path) == outside.path) }
        if mode == "stageDirectory" { #expect(try names(stage(target)).isEmpty) }
        if mode == "contentLink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: stage(target).appendingPathComponent("content").path) == victim.path) }
        if mode == "contentReplace" { #expect(try Data(contentsOf: stage(target).appendingPathComponent("content")) == sentinel) }
        if mode == "sameInode" || mode == "sameSize" { #expect(try names(target).isEmpty) }
    }

    @Test func concurrentServicesPublishExactlyOneWholeFile() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try MobileWorkspaceFileUploadService(rootDirectory: root), second = try MobileWorkspaceFileUploadService(rootDirectory: root)
        let id = try await marker(root), gate = Gate(), firstBytes = Data(repeating: 11, count: 150_001), secondBytes = Data(repeating: 22, count: 200_003)
        let tasks = [(first, firstBytes), (second, secondBytes)].map { service, bytes in
            Task { try await write(service, marker: id, data: bytes, gate: { await gate.enter() }) }
        }
        await gate.wait(2); #expect(try names(root).count == 2); await gate.release()
        var successes = 0, conflicts = 0
        for task in tasks {
            do { _ = try await task.value; successes += 1 }
            catch MobileWorkspaceFileUploadError.alreadyExists { conflicts += 1 }
        }
        #expect(successes == 1 && conflicts == 1)
        let actual = try Data(contentsOf: root.appendingPathComponent("file")); #expect(actual == firstBytes || actual == secondBytes)
        #expect(try names(root) == ["file"]); #expect(await gate.calls == 2)
    }

    @Test func cleanupCannotTurnCommittedFileIntoFailureOrDeleteUnknownEntries() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileUploadService(rootDirectory: root), id = try await marker(root)
        let sentinel = Data("unrecognized private entry".utf8)
        let result = try await write(service, marker: id) {
            try sentinel.write(to: stage(root).appendingPathComponent("keep"))
        }
        #expect(result.relativePath == "file" && result.byteCount == 3)
        #expect(try Data(contentsOf: root.appendingPathComponent("file")) == Data("abc".utf8))
        let remaining = try stage(root)
        #expect(try names(remaining) == ["keep"])
        #expect(try Data(contentsOf: remaining.appendingPathComponent("keep")) == sentinel)
    }

    @Test func realPermissionDenialDoesNotWriteOrCallGate() async throws {
        let root = try fixture(); defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        let id = try await marker(root), service = try MobileWorkspaceFileUploadService(rootDirectory: root), gate = Gate()
        try #require(geteuid() != 0)
        try #require(chmod(root.path, 0o500) == 0)
        await expect(.permissionDenied) { _ = try await write(service, marker: id, gate: { await gate.count() }) }
        #expect(await gate.calls == 0); #expect(try names(root).isEmpty)
    }
}
