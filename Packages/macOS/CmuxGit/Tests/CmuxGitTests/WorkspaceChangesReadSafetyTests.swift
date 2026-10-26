import Foundation
import Testing

@testable import CmuxGit

/// Real Git and public service reads in self-owned repositories, not admission or network coverage.
@Suite struct WorkspaceChangesReadSafetyTests {
    @Test(arguments: ["external", "textconv", "fsmonitor"], [false, true])
    func publicReadsDoNotInvokeConfiguredHelpers(helper: String, untracked: Bool) async throws {
        let repo = try makeRepository()
        let marker = try installHelper(helper, in: repo)
        let path = untracked ? "new.txt" : "tracked.txt"
        // fsmonitor is an index hook; --no-index cannot be its positive control.
        let arguments = untracked && helper != "fsmonitor"
            ? ["diff", "--no-index", "--", "/dev/null", path]
            : ["diff", "HEAD", "--", path]
        try repo.git(arguments, acceptedExitCodes: [0, 1])
        try #require(FileManager.default.fileExists(atPath: marker.path), "Positive control must execute the helper")
        try FileManager.default.removeItem(at: marker)

        let service = WorkspaceChangesService()
        let summary = await service.summary(forDirectory: repo.root.path)
        #expect(summary.isRepository)
        #expect(summary.filesChanged == 2)
        #expect(summary.additions == 2)
        #expect(summary.deletions == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "Snapshot must not invoke configured helper")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }

        let diff = try await service.fileDiff(forDirectory: repo.root.path, path: path)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "File diff must not invoke configured helper")
        #expect(diff.unifiedDiff.contains(untracked ? "+new" : "+after"))
        if !untracked { #expect(diff.unifiedDiff.contains("-before")) }
    }

    @Test func environmentExternalDiffIsIgnoredByDiffFlags() async throws {
        let repo = try makeRepository()
        let marker = try installHelper("external", in: repo)
        try repo.git(["config", "--local", "--unset", "diff.external"])
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_EXTERNAL_DIFF"] = repo.root.appendingPathComponent(".git/probe.sh").path
        let runner = SystemWorkspaceChangesGitRunner(environment: environment)
        let control = try runner.run(arguments: ["diff", "HEAD", "--", "tracked.txt"], in: repo.root)
        #expect(control.exitCode == 0)
        try #require(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        // This injected default runner tests diff flags, not fsmonitor opt-in.
        let service = WorkspaceChangesService(runner: runner)
        let diff = try await service.fileDiff(forDirectory: repo.root.path, path: "tracked.txt")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(diff.unifiedDiff.contains("-before") && diff.unifiedDiff.contains("+after"))
    }

    @Test func defaultRunnerRetainsFilesystemMonitorBehavior() throws {
        let repo = try makeRepository()
        let marker = try installHelper("fsmonitor", in: repo)
        let result = try SystemWorkspaceChangesGitRunner().run(arguments: ["status", "--porcelain"], in: repo.root)
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeRepository() throws -> WorkspaceChangesGitRepositoryFixture {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.git(["config", "--local", "core.hooksPath", "/dev/null"])
        try repo.git(["config", "--local", "commit.gpgsign", "false"])
        try repo.write(".gitattributes", "*.txt diff=probe\n")
        try repo.write("tracked.txt", "before\n")
        try repo.git(["add", "--", ".gitattributes", "tracked.txt"])
        try repo.commit("isolated baseline")
        try repo.write("tracked.txt", "after\n")
        try repo.write("new.txt", "new\n")
        return repo
    }

    private func installHelper(_ helper: String, in repo: WorkspaceChangesGitRepositoryFixture) throws -> URL {
        let marker = repo.root.appendingPathComponent(".git/probe-marker")
        let script = repo.root.appendingPathComponent(".git/probe.sh")
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Shell builtins only: write our marker, then emit a safe fixed response.
        let response = helper == "fsmonitor" ? "printf 'token\\000/\\000'\n" : helper == "textconv" ? "printf 'converted\\n'\n" : ""
        try repo.write(".git/probe.sh", "#!/bin/sh\nprintf 'invoked\\n' > \(quotedMarker)\n" + response)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let key = helper == "external" ? "diff.external" : helper == "textconv" ? "diff.probe.textconv" : "core.fsmonitor"
        try repo.git(["config", "--local", key, script.path])
        return marker
    }
}
