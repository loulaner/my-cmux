import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxMobileHost

@Suite(.timeLimit(.minutes(1)))
struct MobileWorkspaceFileDownloadServiceTests {
    private func fixture() throws -> URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("workspace-download-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func rootID(_ root: URL) async throws -> String {
        try await MobileWorkspaceFileListService(rootDirectory: root).list().rootID
    }

    private func expectError(_ expected: MobileWorkspaceFileDownloadError, service: MobileWorkspaceFileDownloadService,
                             path: String, rootID: String) async {
        do {
            _ = try await service.read(relativePath: path, expectedRootID: rootID)
            Issue.record("Expected safe download error")
        } catch let error as MobileWorkspaceFileDownloadError { #expect(error == expected) }
        catch { Issue.record("Unexpected download error type") }
    }

    @Test(arguments: [0, 3, 7, 262_145, 2_097_152])
    func completeBinaryFiles(size: Int) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("data.bin")
        try bytes.write(to: file)
        let identity = try await rootID(root)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        let result = try await service.read(relativePath: "data.bin", expectedRootID: identity)
        #expect(MobileWorkspaceFileDownloadService.maximumDownloadBytes == 2_097_152)
        #expect(result.data == bytes && result.byteCount == size)
        #expect(result.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(result.sha256.utf8.count == 64 && result.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        #expect(result.relativePath == "data.bin" && result.rootID == identity)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == names)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int == size)
    }

    @Test func knownDigestsAndUninterpretedContent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try await rootID(root)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        for (name, bytes, digest) in [
            ("empty", Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        ] {
            try bytes.write(to: root.appendingPathComponent(name))
            let result = try await service.read(relativePath: name, expectedRootID: identity)
            #expect(result.data == bytes && result.sha256 == digest && result.byteCount == bytes.count)
        }
        for (name, bytes) in [("image.png", Data([0, 255, 254, 0xC0, 0x80, 0x1B])),
                              ("document.html", Data("中文😀\r\n<script>raw</script>".utf8))] {
            try bytes.write(to: root.appendingPathComponent(name))
            #expect(try await service.read(relativePath: name, expectedRootID: identity).data == bytes)
        }
    }

    @Test(arguments: [Int64(2_097_153), Int64(1) << 34])
    func oversizedFilesAreRefusedWithoutPartialSuccess(size: Int64) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized")
        if size == 2_097_153 {
            try Data(repeating: 0xAB, count: Int(size)).write(to: file)
        } else {
            let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            try #require(ftruncate(descriptor, off_t(size)) == 0)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        await expectError(.tooLarge, service: service, path: "oversized", rootID: try await rootID(root))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 == size)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == names)
        if size == 2_097_153 { #expect(try Data(contentsOf: file) == Data(repeating: 0xAB, count: Int(size))) }
    }

    @Test func latestPathVersionAndLiteralNamesRemainComplete() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: root.appendingPathComponent("file"))
        let identity = try await rootID(root)
        // Atomic replacement deliberately gives the selected path a new file object.
        let latest = Data("latest 文本\n".utf8)
        try latest.write(to: root.appendingPathComponent("file"), options: .atomic)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        #expect(try await service.read(relativePath: "file", expectedRootID: identity).data == latest)
        for directory in ["%2e%2e", "~", "中文 []"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: false)
            try latest.write(to: root.appendingPathComponent(directory + "/literal"))
            let result = try await service.read(relativePath: directory + "/literal", expectedRootID: identity)
            #expect(result.data == latest && result.relativePath == directory + "/literal")
        }
        let boundary = Data(repeating: 65, count: 262_143) + Data("中tail".utf8)
        try boundary.write(to: root.appendingPathComponent("boundary"))
        let complete = try await service.read(relativePath: "boundary", expectedRootID: identity)
        #expect(complete.data == boundary && complete.byteCount == boundary.count)
    }

    @Test func validationPrecedesOpeningMissingRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root.appendingPathComponent("missing"))
        for path in ["", "/absolute", ".", "..", "a/../b", "a//b", "a/", "./a", "a/./b", "a\0b", String(repeating: "x", count: 4097)] {
            await expectError(.invalidPath, service: service, path: path, rootID: String(repeating: "0", count: 64))
        }
        for identity in ["", String(repeating: "0", count: 63), String(repeating: "0", count: 65),
                         String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                         String(repeating: "é", count: 64), String(repeating: "0", count: 63) + "\0"] {
            await expectError(.invalidRequest, service: service, path: "file", rootID: identity)
        }
        await expectError(.notFound, service: service, path: "file", rootID: String(repeating: "0", count: 64))
        for invalid in [URL(string: "https://example.invalid/root")!,
                        URL(fileURLWithPath: root.path + "/bad\0root", isDirectory: false),
                        URL(fileURLWithPath: root.path + "/" + String(repeating: "x", count: 4096), isDirectory: false)] {
            #expect(throws: MobileWorkspaceFileDownloadError.invalidPath) { try MobileWorkspaceFileDownloadService(rootDirectory: invalid) }
        }
    }

    @Test func rootMismatchPrecedesTraversalAndReplacedRootIsRejected() async throws {
        let container = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: root.appendingPathComponent("file"))
        let identity = try await rootID(root)
        let wrong = String(identity.first == "0" ? "1" : "0") + identity.dropFirst()
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        await expectError(.rootChanged, service: service, path: "missing-child/file", rootID: wrong)
        await expectError(.rootChanged, service: service, path: "file", rootID: wrong)
        await expectError(.notFound, service: service, path: "missing-child/file", rootID: identity)
        await expectError(.notFound, service: service, path: "missing", rootID: identity)
        try FileManager.default.moveItem(at: root, to: container.appendingPathComponent("retained-old-root"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: root.appendingPathComponent("file"))
        let replacement = try await rootID(root)
        #expect(identity != replacement)
        await expectError(.rootChanged, service: service, path: "file", rootID: identity)
        #expect(try await service.read(relativePath: "file", expectedRootID: replacement).data == Data("new".utf8))
    }

    @Test func outsideLeafSymlinkNeverReturnsBytes() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let marker = Data("OWNED-OUTSIDE-DOWNLOAD-MARKER".utf8)
        try marker.write(to: outside.appendingPathComponent("marker"))
        try #require(symlink(outside.appendingPathComponent("marker").path, root.appendingPathComponent("link").path) == 0)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        do {
            let result = try await service.read(relativePath: "link", expectedRootID: rootID(root))
            #expect(result.data != marker, "Outside fixture bytes must not be returned through a leaf symlink")
            Issue.record("Leaf symlink unexpectedly succeeded")
        } catch let error as MobileWorkspaceFileDownloadError { #expect(error == .notRegularFile) }
    }

    @Test func rootsParentsLinksDirectoriesAndFIFOsAreRejected() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false)
        try #require(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
        for (name, target) in [("inside-file", root.appendingPathComponent("file")), ("inside-dir", root.appendingPathComponent("dir")),
                               ("outside-dir", outside), ("broken", outside.appendingPathComponent("missing"))] {
            try #require(symlink(target.path, root.appendingPathComponent(name).path) == 0)
        }
        let identity = try await rootID(root)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        for name in ["inside-file", "broken", "dir", "fifo", "inside-dir/file", "outside-dir/file", "file/child"] {
            await expectError(.notRegularFile, service: service, path: name, rootID: identity)
        }
        let outsideID = try await rootID(outside)
        for trailing in [false, true] {
            let linkedRoot = URL(fileURLWithPath: root.appendingPathComponent("outside-dir").path, isDirectory: trailing)
            await expectError(.notRegularFile, service: try MobileWorkspaceFileDownloadService(rootDirectory: linkedRoot), path: "file", rootID: outsideID)
        }
        // Repeated success/error ownership paths, not a process-wide FD-count claim.
        for _ in 0..<64 {
            #expect(try await service.read(relativePath: "file", expectedRootID: identity).data == Data("inside".utf8))
            await expectError(.notRegularFile, service: service, path: "inside-file", rootID: identity)
            await expectError(.notFound, service: service, path: "missing", rootID: identity)
        }
    }

    @Test func permissionDenialWhenEnforced() async throws {
        let root = try fixture()
        let directory = root.appendingPathComponent("private")
        let file = root.appendingPathComponent("file")
        defer { chmod(file.path, 0o600); chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("private".utf8).write(to: file)
        let identity = try await rootID(root)
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root)
        for (target, flags, requested) in [(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK, "file"),
                                           (directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK, "private/file")] {
            try #require(chmod(target.path, 0) == 0)
            let probe = open(target.path, flags)
            if probe >= 0 { close(probe); Issue.record("Fixture permission denial was bypassed by the test identity"); continue }
            try #require(errno == EACCES || errno == EPERM)
            await expectError(.permissionDenied, service: service, path: requested, rootID: identity)
        }
    }

    @Test func preCancelledRequestsDoNotOpenMissingRoot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileDownloadService(rootDirectory: root.appendingPathComponent("missing"))
        for _ in 0..<64 {
            let (barrier, release) = AsyncStream<Void>.makeStream()
            let task = Task {
                var iterator = barrier.makeAsyncIterator()
                _ = await iterator.next()
                do {
                    _ = try await service.read(relativePath: "file", expectedRootID: String(repeating: "0", count: 64))
                    Issue.record("Expected cancellation before opening")
                } catch is CancellationError {}
                catch { Issue.record("Cancellation must propagate unchanged") }
            }
            task.cancel(); release.yield(()); release.finish()
            await task.value
        }
    }
}
