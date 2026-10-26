import Foundation
import Testing

@testable import CmuxGit

/// Missing objects must not turn a workspace read into an implicit transport invocation.
@Suite struct WorkspaceChangesLocalObjectsTests {
    @Test(arguments: ["summary", "changedFiles", "fileDiff"])
    func missingBlobDoesNotInvokeTransport(api: String) async throws {
        let repo = try makeRepository()
        let marker = try removeOwnBlobAndConfigurePromisor(in: repo)
        // Default runner remains unrestricted for explicit Git/reference operations.
        // This ext helper only writes our marker and exits 1; it cannot fetch anything.
        let control = try SystemWorkspaceChangesGitRunner().run(
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", "sample.txt"],
            in: repo.root
        )
        // Git may fail directly or the bounded runner may terminate retries at its deadline.
        #expect(control.exitCode != 0)
        try #require(FileManager.default.fileExists(atPath: marker.path), "Transport positive control must execute")
        try FileManager.default.removeItem(at: marker)

        // Each parameter case owns a fresh repo/service; no cached snapshot can hide a read.
        let service = WorkspaceChangesService()
        switch api {
        case "summary":
            let summary = await service.summary(forDirectory: repo.root.path)
            #expect(summary == .notARepository)
        case "changedFiles":
            await #expect(throws: WorkspaceChangesServiceError.gitFailure) {
                try await service.changedFiles(forDirectory: repo.root.path)
            }
        default:
            await #expect(throws: WorkspaceChangesServiceError.gitFailure) {
                try await service.fileDiff(forDirectory: repo.root.path, path: "sample.txt")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "Public read must not invoke transport")
    }

    @Test func completeLocalObjectsRetainReadResults() async throws {
        let repo = try makeRepository()
        let service = WorkspaceChangesService()
        let summary = await service.summary(forDirectory: repo.root.path)
        #expect(summary.isRepository && summary.filesChanged == 1)
        #expect(summary.additions == 1 && summary.deletions == 1)
        let changed = try await service.changedFiles(forDirectory: repo.root.path)
        #expect(changed.files.map(\.path) == ["sample.txt"])
        let diff = try await service.fileDiff(forDirectory: repo.root.path, path: "sample.txt")
        #expect(diff.unifiedDiff.contains("-base!") && diff.unifiedDiff.contains("+after"))
        let base = try await service.fileFetch(
            forDirectory: repo.root.path, path: "sample.txt", revision: .base, offset: 0, length: 64
        )
        #expect(base.data == Data("base!\n".utf8))
        #expect(base.eof)
    }

    private func makeRepository() throws -> WorkspaceChangesGitRepositoryFixture {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.git(["config", "--local", "core.hooksPath", "/dev/null"])
        try repo.git(["config", "--local", "commit.gpgsign", "false"])
        try repo.write("sample.txt", "base!\n")
        try repo.git(["add", "--", "sample.txt"])
        try repo.commit("self-owned local object baseline")
        try repo.write("sample.txt", "after\n")
        return repo
    }

    private func removeOwnBlobAndConfigurePromisor(in repo: WorkspaceChangesGitRepositoryFixture) throws -> URL {
        let oid = String(decoding: try repo.git(["rev-parse", "HEAD:sample.txt"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require([40, 64].contains(oid.count) && oid.allSatisfy { "0123456789abcdef".contains($0) })
        // Only the loose blob just created by this fixture may be removed.
        let ownBlob = try repo.git(["cat-file", "blob", oid])
        try #require(ownBlob == Data("base!\n".utf8))
        let root = repo.root.resolvingSymlinksInPath()
        let objects = root.appendingPathComponent(".git/objects", isDirectory: true)
        let blob = objects.appendingPathComponent(String(oid.prefix(2)))
            .appendingPathComponent(String(oid.dropFirst(2)))
        try #require(objects.resolvingSymlinksInPath().path == objects.path)
        try #require(blob.resolvingSymlinksInPath().path == blob.path)
        try #require(blob.path.hasPrefix(objects.path + "/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: blob.path)
        try #require(attributes[.type] as? FileAttributeType == .typeRegular)
        try FileManager.default.removeItem(at: blob)
        try #require(!FileManager.default.fileExists(atPath: blob.path))

        let marker = root.appendingPathComponent(".git/lazy-marker")
        let script = root.appendingPathComponent(".git/offline helper%.sh")
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data("#!/bin/sh\nprintf 'invoked\\n' > \(quotedMarker)\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // remote-ext escapes literal '%' as '%%' and spaces as '% ', not shell quoting.
        let command = script.path.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: " ", with: "% ")
        try repo.git(["config", "--local", "remote.origin.url", "ext::" + command])
        try repo.git(["config", "--local", "remote.origin.promisor", "true"])
        try repo.git(["config", "--local", "remote.origin.partialclonefilter", "blob:none"])
        try repo.git(["config", "--local", "protocol.ext.allow", "always"])
        return marker
    }
}
