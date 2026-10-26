import Darwin
import Foundation
import Testing
@testable import CmuxMobileHost

struct MobileWorkspaceFileListServiceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func expectError(_ expected: MobileWorkspaceFileListError, service: MobileWorkspaceFileListService,
                             path: String = "", offset: Int = 0, limit: Int = 100) async {
        do {
            _ = try await service.list(relativePath: path, offset: offset, limit: limit)
            Issue.record("Expected typed listing failure")
        } catch let error as MobileWorkspaceFileListError { #expect(error == expected) }
        catch { Issue.record("Unexpected error type") }
    }

    @Test func namesMetadataParentsAndPagination() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["z", "B", ".hidden", "中文 []"] {
            try Data("abc".utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: root.appendingPathComponent("a/b/file"))
        for name in ["%2e%2e", "~"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            try Data().write(to: root.appendingPathComponent(name + "/literal"))
        }
        let service = try MobileWorkspaceFileListService(rootDirectory: root)
        for name in ["%2e%2e", "~"] {
            let literal = try await service.list(relativePath: name)
            #expect(literal.parentRelativePath == "" && literal.entries.map(\.relativePath) == [name + "/literal"])
        }
        let page = try await service.list()
        #expect(page.entries.map(\.name) == ["%2e%2e", ".hidden", "B", "a", "z", "~", "中文 []"])
        #expect(page.entries.map(\.relativePath) == page.entries.map(\.name))
        #expect(page.entries.filter { $0.kind == .file }.allSatisfy { $0.byteCount == 3 })
        #expect(page.entries.first { $0.name == "a" }?.kind == .directory)
        #expect(page.entries.first { $0.name == "a" }?.byteCount == nil)
        #expect(page.parentRelativePath == nil && page.relativePath == "")
        #expect(page.offset == 0 && page.limit == 100 && page.totalCount == 7 && page.nextOffset == nil)
        let first = try await service.list(limit: 1)
        #expect(first.entries.map(\.name) == ["%2e%2e"] && first.nextOffset == 1)
        let middle = try await service.list(offset: 3, limit: 1)
        #expect(middle.entries.map(\.name) == ["a"] && middle.nextOffset == 4)
        let last = try await service.list(offset: 6, limit: 1)
        #expect(last.entries.map(\.name) == ["中文 []"] && last.nextOffset == nil)
        for offset in [7, 8, Int.max] {
            let end = try await service.list(offset: offset)
            #expect(end.entries.isEmpty && end.offset == 7 && end.totalCount == 7 && end.nextOffset == nil)
        }
        let firstLevel = try await service.list(relativePath: "a")
        #expect(firstLevel.parentRelativePath == "" && firstLevel.entries.map(\.relativePath) == ["a/b"])
        let secondLevel = try await service.list(relativePath: "a/b")
        #expect(secondLevel.parentRelativePath == "a" && secondLevel.entries.map(\.relativePath) == ["a/b/file"])
        #expect(secondLevel.entries.first?.byteCount == 4)
    }

    @Test func validationPrecedesFilesystem() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileListService(rootDirectory: root.appendingPathComponent("missing"))
        for path in ["/absolute", "a/../outside", ".", "..", "a//b", "a/", "./a", "a/./b", "a\0b", String(repeating: "x", count: 4097)] {
            await expectError(.invalidPath, service: service, path: path)
        }
        for (offset, limit) in [(-1, 100), (0, 0), (0, 101)] {
            await expectError(.invalidRequest, service: service, offset: offset, limit: limit)
        }
        await expectError(.notFound, service: service)
        let invalidRoots = [
            URL(string: "https://example.invalid/root")!,
            URL(fileURLWithPath: root.path + "/" + String(repeating: "x", count: 4096), isDirectory: false),
            URL(fileURLWithPath: root.path + "/bad\0root", isDirectory: false),
        ]
        for url in invalidRoots {
            #expect(throws: MobileWorkspaceFileListError.invalidPath) { try MobileWorkspaceFileListService(rootDirectory: url) }
        }
    }

    @Test func noSymlinkTraversalAndNoContentOpen() async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("file"))
        try Data().write(to: outside.appendingPathComponent("OUTSIDE-MARKER"))
        let links = [("inside-dir", root.appendingPathComponent("dir").path), ("outside-dir", outside.path),
                     ("inside-file", root.appendingPathComponent("file").path),
                     ("outside-file", outside.appendingPathComponent("OUTSIDE-MARKER").path),
                     ("broken", outside.appendingPathComponent("missing").path)]
        for (name, target) in links { #expect(symlink(target, root.appendingPathComponent(name).path) == 0) }
        #expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
        let service = try MobileWorkspaceFileListService(rootDirectory: root)
        let page = try await service.list()
        #expect(!page.entries.contains { $0.name == "OUTSIDE-MARKER" })
        for (name, _) in links {
            let entry = try #require(page.entries.first { $0.name == name })
            #expect(entry.kind == .symbolicLink && entry.byteCount == nil)
            await expectError(.notDirectory, service: service, path: name)
            await expectError(.notDirectory, service: service, path: name + "/child")
        }
        #expect(page.entries.first { $0.name == "fifo" }?.kind == .other)
        #expect(page.entries.first { $0.name == "fifo" }?.byteCount == nil)
        for name in ["outside-dir", "inside-dir", "file", "fifo"] {
            let invalidRoot = try MobileWorkspaceFileListService(rootDirectory: root.appendingPathComponent(name))
            await expectError(.notDirectory, service: invalidRoot)
        }
        let slashRoot = try MobileWorkspaceFileListService(
            rootDirectory: URL(fileURLWithPath: root.appendingPathComponent("outside-dir").path, isDirectory: true))
        await expectError(.notDirectory, service: slashRoot)
        await expectError(.notFound, service: service, path: "missing")
        // Repeat success/error paths without treating process-wide FD counts as a proof.
        for _ in 0..<64 {
            _ = try await service.list(relativePath: "dir")
            await expectError(.notDirectory, service: service, path: "inside-dir")
        }
    }

    @Test func exactEnumerationBudget() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10_000 { try Data().write(to: root.appendingPathComponent("f\(index)")) }
        let service = try MobileWorkspaceFileListService(rootDirectory: root)
        let page = try await service.list(limit: 100)
        #expect(page.totalCount == 10_000 && page.entries.count == 100 && page.nextOffset == 100)
        try Data().write(to: root.appendingPathComponent("overflow"))
        await expectError(.tooManyEntries, service: service, limit: 1)
    }

    @Test func invalidUTF8NameFailsRatherThanLossyListing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let name: [CChar] = [-1, 0]
        let file = name.withUnsafeBufferPointer { openat(fd, $0.baseAddress!, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600) }
        if file < 0 {
            try #require(errno == EILSEQ || errno == EINVAL)
            print("UNVERIFIED non-UTF8 entry: fixture filesystem rejects this name")
            return
        }
        close(file)
        let service = try MobileWorkspaceFileListService(rootDirectory: root)
        await expectError(.unreadable, service: service)
    }

    @Test func permissionFailureWhenEnforced() async throws {
        let root = try fixture()
        defer { chmod(root.path, 0o700); try? FileManager.default.removeItem(at: root) }
        #expect(chmod(root.path, 0) == 0)
        let probe = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        if probe >= 0 { close(probe); print("UNVERIFIED permission denial: current identity bypasses directory mode"); return }
        try #require(errno == EACCES || errno == EPERM)
        await expectError(.permissionDenied, service: try MobileWorkspaceFileListService(rootDirectory: root))
    }

    @Test func preCancelledTaskBeforeRootOpen() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try MobileWorkspaceFileListService(rootDirectory: root.appendingPathComponent("missing"))
        // No value is released before cancellation, even if the task has not
        // started yet. AsyncStream also releases its waiter on cancellation.
        let (barrier, release) = AsyncStream<Void>.makeStream()
        let task = Task {
            var iterator = barrier.makeAsyncIterator()
            _ = await iterator.next()
            do { _ = try await service.list(); Issue.record("Expected cancellation before missing root open") }
            catch is CancellationError {}
            catch { Issue.record("Cancellation was not propagated") }
        }
        task.cancel()
        release.yield(())
        release.finish()
        await task.value
    }

}
