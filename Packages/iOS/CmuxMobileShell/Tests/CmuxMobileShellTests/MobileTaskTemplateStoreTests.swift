import Foundation
import Testing
@testable import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
@Suite(.serialized) struct MobileTaskTemplateStoreTests {
    @Test func seededTemplatesCannotBeDeleted() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)

        #expect(store.listTemplates().map(\.name) == ["Claude", "Codex", "OpenCode", "Shell"])

        store.deleteTemplate(id: store.listTemplates()[0].id)
        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)

        #expect(reloaded.listTemplates().map(\.name) == ["Claude", "Codex", "OpenCode", "Shell"])
    }

    @Test func seedingV4ClearsAbandonedV1V2AndV3Keys() {
        let defaults = Self.defaults()
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v1")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v1")
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v2")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v2")
        defaults.set(Data("stale".utf8), forKey: "cmux.mobile.taskTemplates.v3")
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v3")

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(store.listTemplates().count == 4)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v1") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v2") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v2") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.v3") == nil)
        #expect(defaults.object(forKey: "cmux.mobile.taskTemplates.seeded.v3") == nil)
    }

    @Test func crudPersistsAcrossStoreInstances() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let custom = MobileTaskTemplate(name: "Build", icon: "hammer", command: "swift test", defaultDirectory: "~/dev")

        store.addTemplate(custom)
        var updated = custom
        updated.name = "Test"
        updated.command = "swift test --parallel"
        store.updateTemplate(updated)

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.listTemplates().contains(updated))

        reloaded.deleteTemplate(id: updated.id)
        #expect(!UserDefaultsMobileTaskTemplateStore(defaults: defaults).listTemplates().contains(updated))
    }

    @Test func deletingEveryTemplateKeepsBuiltInSeedsAfterRelaunch() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let seeds = store.listTemplates()

        for template in seeds {
            store.deleteTemplate(id: template.id)
        }

        #expect(store.listTemplates() == seeds)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).listTemplates() == seeds)
    }

    @Test func batchDeletionPersistsAndClearsTheLastSelection() throws {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let seeds = store.listTemplates()
        let customTemplates = [
            MobileTaskTemplate(name: "Build", icon: "hammer", command: "swift build"),
            MobileTaskTemplate(name: "Test", icon: "checkmark", command: "swift test"),
        ]
        for template in customTemplates {
            store.addTemplate(template)
        }
        let deletedIDs = Set(customTemplates.map(\.id))
        let selectedID = try #require(customTemplates.last?.id)
        store.setLastTemplateID(selectedID)

        store.deleteTemplates(ids: deletedIDs)

        #expect(Set(store.listTemplates().map(\.id)).isDisjoint(with: deletedIDs))
        #expect(store.listTemplates() == seeds)
        #expect(store.lastTemplateID() == nil)
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).listTemplates() == store.listTemplates())
    }

    @Test func batchDeletionKeepsSeedsAndDeletesCustomTemplates() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let seeds = store.listTemplates()
        let custom = MobileTaskTemplate(name: "Custom", icon: "hammer", command: "custom-agent")
        store.addTemplate(custom)

        store.deleteTemplates(ids: Set(seeds.map(\.id) + [custom.id]))

        #expect(store.listTemplates() == seeds)
    }

    @Test func legacyV4SeedsGainProtectionWithoutReplacingCustomTemplates() throws {
        let defaults = Self.defaults()
        var legacySeeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Renamed Claude",
            codexName: "Codex",
            openCodeName: "OpenCode",
            shellName: "Shell"
        )
        for index in legacySeeds.indices {
            legacySeeds[index].isBuiltIn = false
            legacySeeds[index].builtInKind = nil
        }
        let custom = MobileTaskTemplate(
            name: "Custom",
            icon: "hammer",
            command: "custom-agent"
        )
        let storedTemplates = legacySeeds + [custom]
        defaults.set(
            try JSONEncoder().encode(storedTemplates),
            forKey: "cmux.mobile.taskTemplates.v4"
        )
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v4")

        let migrated = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
            .listTemplates()

        #expect(migrated.map(\.id) == storedTemplates.map(\.id))
        #expect(migrated.prefix(4).allSatisfy { $0.isBuiltIn })
        #expect(migrated.last?.isBuiltIn == false)
    }

    @Test func completedProtectionMigrationRestoresAPreviouslyDeletedShellSeed() throws {
        let defaults = Self.defaults()
        var survivingSeeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Claude",
            codexName: "Codex",
            openCodeName: "OpenCode",
            shellName: "Shell"
        )
        survivingSeeds.removeLast()
        for index in survivingSeeds.indices {
            survivingSeeds[index].builtInKind = nil
            survivingSeeds[index].isBuiltIn = true
        }
        let custom = MobileTaskTemplate(
            name: "Custom",
            icon: "hammer",
            command: "custom-agent"
        )
        defaults.set(
            try JSONEncoder().encode(survivingSeeds + [custom]),
            forKey: "cmux.mobile.taskTemplates.v4"
        )
        defaults.set(true, forKey: "cmux.mobile.taskTemplates.seeded.v4")
        defaults.set(
            true,
            forKey: "cmux.mobile.taskTemplates.builtInProtectionMigrated.v1"
        )

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let reconciled = store.listTemplates()

        #expect(reconciled.map(\.name) == ["Claude", "Codex", "OpenCode", "Shell", "Custom"])
        let restoredShell = try #require(reconciled.first { $0.name == "Shell" })
        #expect(restoredShell.isBuiltIn)
        #expect(reconciled.first { $0.id == custom.id }?.isBuiltIn == false)

        store.deleteTemplate(id: restoredShell.id)
        #expect(store.listTemplates().contains { $0.id == restoredShell.id })
    }

    @Test func mutationsCannotForgeOrRemoveBuiltInProvenance() throws {
        let store = UserDefaultsMobileTaskTemplateStore(defaults: Self.defaults())
        var builtIn = try #require(store.listTemplates().first)
        builtIn.isBuiltIn = false
        builtIn.name = "Edited Claude"
        store.updateTemplate(builtIn)

        var custom = MobileTaskTemplate(
            name: "Custom",
            icon: "hammer",
            command: "custom-agent",
            isBuiltIn: true
        )
        store.addTemplate(custom)
        custom.name = "Edited Custom"
        store.updateTemplate(custom)

        let templates = store.listTemplates()
        #expect(templates.first { $0.id == builtIn.id }?.isBuiltIn == true)
        #expect(templates.first { $0.id == custom.id }?.isBuiltIn == false)
    }

    @Test func lastUsedValuesRoundTrip() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let templateID = UUID()

        store.setLastTemplateID(templateID)
        store.setLastMacDeviceID("mac-a")
        store.setLastDirectory("~/work", macDeviceID: "mac-a")
        store.setLastDirectory("/tmp/other", macDeviceID: "mac-b")

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.lastTemplateID() == templateID)
        #expect(reloaded.lastMacDeviceID() == "mac-a")
        #expect(reloaded.lastDirectory(macDeviceID: "mac-a") == "~/work")
        #expect(reloaded.lastDirectory(macDeviceID: "mac-b") == "/tmp/other")

        reloaded.setLastTemplateID(nil)
        reloaded.setLastMacDeviceID(nil)
        reloaded.setLastDirectory(nil, macDeviceID: "mac-a")
        #expect(reloaded.lastTemplateID() == nil)
        #expect(reloaded.lastMacDeviceID() == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "mac-a") == nil)
    }

    @Test func recentDirectoriesAreByteExactPromotedBoundedAndMacScoped() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let base = Date(timeIntervalSince1970: 1_000)
        let composed = "~/caf\u{00E9}"
        let decomposed = "~/cafe\u{301}"

        store.recordRecentDirectory(composed, macDeviceID: "mac-a", at: base)
        store.recordRecentDirectory(decomposed, macDeviceID: "mac-a", at: base.addingTimeInterval(1))
        store.recordRecentDirectory(composed, macDeviceID: "mac-a", at: base.addingTimeInterval(2))
        store.recordRecentDirectory("~/other", macDeviceID: "mac-b", at: base)

        let byteExact = store.recentDirectories(macDeviceID: "mac-a")
        #expect(byteExact.count == 2)
        #expect(byteExact[0].path == composed)
        #expect(byteExact[0].useCount == 2)
        #expect(Array(byteExact[1].path.utf8) == Array(decomposed.utf8))

        for index in 0..<24 {
            store.recordRecentDirectory("~/project-\(index)", macDeviceID: "mac-a", at: base.addingTimeInterval(Double(index + 3)))
        }

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let macA = reloaded.recentDirectories(macDeviceID: "mac-a")
        #expect(macA.count == 20)
        #expect(macA.first?.path == "~/project-23")
        #expect(reloaded.recentDirectories(macDeviceID: "mac-b").map(\.path) == ["~/other"])
    }

    @Test func composerDraftsRoundTripNewestFirstAcrossStoreInstances() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let operationID = UUID()
        let older = MobileTaskComposerSavedDraft(
            updatedAt: Date(timeIntervalSince1970: 100),
            content: MobileTaskComposerDraft(
                prompt: "Fix the reconnect flow\nthen test it",
                templateID: UUID(),
                macDeviceID: "mac-a",
                directory: "~/Dev/cmux",
                didEditDirectory: true,
                operationID: operationID
            )
        )
        let newer = MobileTaskComposerSavedDraft(
            updatedAt: Date(timeIntervalSince1970: 200),
            content: MobileTaskComposerDraft(
                prompt: "Ship drafts",
                templateID: nil,
                macDeviceID: "mac-b",
                directory: "~/Dev/other",
                didEditDirectory: false
            )
        )

        store.saveComposerDraft(older)
        store.saveComposerDraft(newer)

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.composerDrafts() == [newer, older])
        #expect(reloaded.composerDraft(id: older.id)?.content.operationID == operationID)

        reloaded.deleteComposerDrafts(ids: [newer.id])
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDrafts() == [older])

        reloaded.deleteComposerDrafts(ids: [older.id])
        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDrafts().isEmpty)
    }

    @Test func savingAnExistingDraftIDReplacesItsEntryAndPromotesIt() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let sessionID = UUID()
        let first = MobileTaskComposerSavedDraft(
            id: sessionID,
            updatedAt: Date(timeIntervalSince1970: 100),
            content: Self.draftContent(prompt: "First pass")
        )
        let other = MobileTaskComposerSavedDraft(
            updatedAt: Date(timeIntervalSince1970: 150),
            content: Self.draftContent(prompt: "Other task")
        )
        let revised = MobileTaskComposerSavedDraft(
            id: sessionID,
            updatedAt: Date(timeIntervalSince1970: 200),
            content: Self.draftContent(prompt: "Revised pass")
        )

        store.saveComposerDraft(first)
        store.saveComposerDraft(other)
        store.saveComposerDraft(revised)

        let drafts = store.composerDrafts()
        #expect(drafts == [revised, other])
        #expect(drafts.first?.content.prompt == "Revised pass")
    }

    @Test func composerDraftStorageIsBounded() {
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)

        for index in 0..<25 {
            store.saveComposerDraft(MobileTaskComposerSavedDraft(
                updatedAt: Date(timeIntervalSince1970: Double(index)),
                content: Self.draftContent(prompt: "Task \(index)")
            ))
        }

        let drafts = UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDrafts()
        #expect(drafts.count == 20)
        #expect(drafts.first?.content.prompt == "Task 24")
        #expect(drafts.last?.content.prompt == "Task 5")
    }

    @Test func legacySingleSlotDraftMigratesIntoCollectionOnce() throws {
        let defaults = Self.defaults()
        let legacy = MobileTaskComposerDraft(
            prompt: "Prepared on an older build",
            templateID: UUID(),
            macDeviceID: "mac-a",
            directory: "~/Dev/cmux",
            didEditDirectory: true,
            operationID: UUID()
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: "cmux.mobile.taskComposer.draft.v1"
        )

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let migrated = store.composerDrafts()
        #expect(migrated.map(\.content) == [legacy])
        #expect(defaults.data(forKey: "cmux.mobile.taskComposer.draft.v1") == nil)

        // A second read must not duplicate the adopted draft.
        #expect(store.composerDrafts() == migrated)
        store.deleteComposerDrafts(ids: [try #require(migrated.first).id])
        #expect(store.composerDrafts().isEmpty)
    }

    @Test func legacyEmptyDraftIsDroppedInsteadOfMigrated() throws {
        let defaults = Self.defaults()
        let legacy = MobileTaskComposerDraft(
            prompt: "   ",
            templateID: UUID(),
            macDeviceID: "mac-a",
            directory: "~/Dev/cmux",
            didEditDirectory: true
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: "cmux.mobile.taskComposer.draft.v1"
        )

        let store = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(store.composerDrafts().isEmpty)
        #expect(defaults.data(forKey: "cmux.mobile.taskComposer.draft.v1") == nil)
    }

    @Test func signOutClearsPersistedComposerDraftsBeforeAnotherAccountCanRestoreThem() {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        templateStore.saveComposerDraft(MobileTaskComposerSavedDraft(
            updatedAt: Date(),
            content: MobileTaskComposerDraft(
                prompt: "Account A secret",
                templateID: nil,
                macDeviceID: "mac-a",
                directory: "~/Account-A",
                didEditDirectory: true
            )
        ))
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)

        shell.signOut()

        #expect(UserDefaultsMobileTaskTemplateStore(defaults: defaults).composerDrafts().isEmpty)
    }

    @Test func signOutClearsAllTemplateDataAndNextListReseedsSafeDefaults() throws {
        let defaults = Self.defaults()
        let templateStore = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        let custom = MobileTaskTemplate(
            name: "Account A executable",
            icon: "terminal",
            command: "/Users/account-a/bin/private-agent",
            defaultDirectory: "/Users/account-a/secret"
        )
        templateStore.addTemplate(custom)
        templateStore.setLastTemplateID(custom.id)
        templateStore.setLastMacDeviceID("account-a-mac")
        templateStore.setLastDirectory("/Users/account-a/project", macDeviceID: "account-a-mac")
        templateStore.setLastDirectory("/tmp/account-a", macDeviceID: "other-mac")
        templateStore.saveComposerDraft(MobileTaskComposerSavedDraft(
            updatedAt: Date(),
            content: MobileTaskComposerDraft(
                prompt: "Account A secret",
                templateID: custom.id,
                macDeviceID: "account-a-mac",
                directory: "/Users/account-a/project",
                didEditDirectory: true
            )
        ))
        let shell = MobileShellComposite(isSignedIn: true, taskTemplateStore: templateStore)

        shell.signOut()

        let reloaded = UserDefaultsMobileTaskTemplateStore(defaults: defaults)
        #expect(reloaded.lastTemplateID() == nil)
        #expect(reloaded.lastMacDeviceID() == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "account-a-mac") == nil)
        #expect(reloaded.lastDirectory(macDeviceID: "other-mac") == nil)
        #expect(reloaded.composerDrafts().isEmpty)
        let seeds = reloaded.listTemplates()
        #expect(seeds.map(\.command) == [
            "claude -- \"$CMUX_TASK_PROMPT\"",
            "codex -- \"$CMUX_TASK_PROMPT\"",
            "opencode --prompt \"$CMUX_TASK_PROMPT\"",
            "",
        ])
        #expect(!seeds.contains(where: { $0.id == custom.id }))
        #expect(!seeds.contains(where: { $0.command.contains("account-a") }))
        #expect(defaults.bool(forKey: "cmux.mobile.taskTemplates.seeded.v4"))
    }

    @Test func draftAttachmentFilesPersistRestoreAndDeleteWithTheirDraft() throws {
        let root = Self.attachmentsRoot()
        let store = UserDefaultsMobileTaskTemplateStore(
            defaults: Self.defaults(),
            attachmentFilesRootDirectory: root
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-attachment-source-\(UUID().uuidString).txt")
        try Data("attached bytes".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let draftID = UUID()
        let attachmentID = UUID()

        let relativePath = try store.persistComposerAttachmentFile(
            draftID: draftID,
            attachmentID: attachmentID,
            preferredExtension: "TXT",
            from: source
        )

        let preserved = try #require(store.composerAttachmentFileURL(relativePath: relativePath))
        #expect(try Data(contentsOf: preserved) == Data("attached bytes".utf8))
        // Persisting the same attachment again reuses the existing copy.
        #expect(try store.persistComposerAttachmentFile(
            draftID: draftID,
            attachmentID: attachmentID,
            preferredExtension: "TXT",
            from: source
        ) == relativePath)
        // Paths cannot escape the attachment root.
        #expect(store.composerAttachmentFileURL(relativePath: "../\(relativePath)") == nil)

        var content = Self.draftContent(prompt: "With attachment")
        content.attachments = [MobileTaskComposerDraftAttachment(
            id: attachmentID,
            kind: "file",
            displayName: "notes.txt",
            relativePath: relativePath,
            byteCount: 14
        )]
        store.saveComposerDraft(MobileTaskComposerSavedDraft(
            id: draftID,
            updatedAt: Date(),
            content: content
        ))

        store.deleteComposerDrafts(ids: [draftID])
        #expect(store.composerDrafts().isEmpty)
        #expect(store.composerAttachmentFileURL(relativePath: relativePath) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func resavingADraftWithoutAnAttachmentDeletesItsPreservedFile() throws {
        let root = Self.attachmentsRoot()
        let store = UserDefaultsMobileTaskTemplateStore(
            defaults: Self.defaults(),
            attachmentFilesRootDirectory: root
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-attachment-source-\(UUID().uuidString).txt")
        try Data("removable".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let draftID = UUID()
        let relativePath = try store.persistComposerAttachmentFile(
            draftID: draftID,
            attachmentID: UUID(),
            preferredExtension: "txt",
            from: source
        )
        var content = Self.draftContent(prompt: "With attachment")
        content.attachments = [MobileTaskComposerDraftAttachment(
            id: UUID(),
            kind: "file",
            displayName: "notes.txt",
            relativePath: relativePath,
            byteCount: 9
        )]
        store.saveComposerDraft(MobileTaskComposerSavedDraft(
            id: draftID,
            updatedAt: Date(),
            content: content
        ))
        #expect(store.composerAttachmentFileURL(relativePath: relativePath) != nil)

        content.attachments = []
        store.saveComposerDraft(MobileTaskComposerSavedDraft(
            id: draftID,
            updatedAt: Date(),
            content: content
        ))

        #expect(store.composerAttachmentFileURL(relativePath: relativePath) == nil)
        #expect(store.composerDrafts().count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func clearAllUserDataRemovesPreservedAttachmentFiles() throws {
        let root = Self.attachmentsRoot()
        let defaults = Self.defaults()
        let store = UserDefaultsMobileTaskTemplateStore(
            defaults: defaults,
            attachmentFilesRootDirectory: root
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-attachment-source-\(UUID().uuidString).png")
        try Data([9, 9, 9]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let relativePath = try store.persistComposerAttachmentFile(
            draftID: UUID(),
            attachmentID: UUID(),
            preferredExtension: "png",
            from: source
        )
        #expect(store.composerAttachmentFileURL(relativePath: relativePath) != nil)

        store.clearAllUserData()

        #expect(store.composerAttachmentFileURL(relativePath: relativePath) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private static func attachmentsRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MobileTaskTemplateStoreTests-attachments-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static func draftContent(prompt: String) -> MobileTaskComposerDraft {
        MobileTaskComposerDraft(
            prompt: prompt,
            templateID: nil,
            macDeviceID: "mac-a",
            directory: "~/Dev/cmux",
            didEditDirectory: false
        )
    }

    private static func defaults() -> UserDefaults {
        let suiteName = "MobileTaskTemplateStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
