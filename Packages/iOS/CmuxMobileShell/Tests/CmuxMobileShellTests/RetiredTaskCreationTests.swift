import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct RetiredTaskCreationTests {
    @Test func startupLeavesHistoricalDefaultsAndDraftFilesUntouchedUntilSignOut() throws {
        let suite = "RetiredTaskCreationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("historical bytes, not a draft decoder fixture".utf8)
        let file = directory.appendingPathComponent("preserved-attachment")
        try bytes.write(to: file)
        for key in ["cmux.mobile.taskComposer.drafts.v1", "cmux.mobile.taskComposer.draft.v1",
                    "cmux.mobile.taskTemplates.v1", "cmux.mobile.taskTemplates.v4"] {
            defaults.set(bytes, forKey: key)
        }
        let original = try #require(defaults.persistentDomain(forName: suite)) as NSDictionary
        let legacyStore = UserDefaultsMobileTaskTemplateStore(
            defaults: defaults, attachmentFilesRootDirectory: directory
        )
        let shell = MobileShellComposite(
            isSignedIn: true, pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults, taskTemplateStore: legacyStore
        )
        #expect(original.isEqual(to: try #require(defaults.persistentDomain(forName: suite))))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!defaults.bool(forKey: "cmux.mobile.taskTemplates.seeded.v4"))
        // Existing account-boundary cleanup is intentionally retained, only in this fixture.
        shell.signOut()
        #expect(defaults.data(forKey: "cmux.mobile.taskComposer.drafts.v1") == nil)
        #expect(defaults.data(forKey: "cmux.mobile.taskTemplates.v1") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
