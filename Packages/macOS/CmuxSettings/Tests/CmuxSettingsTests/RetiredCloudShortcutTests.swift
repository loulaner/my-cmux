import CmuxSettings
import Testing

struct RetiredCloudShortcutTests {
    @Test(arguments: [ShortcutAction.newCloudWorkspace, .newCloudMachine])
    func retiredBindingsNeverExecute(action: ShortcutAction) {
        let single = StoredShortcut(first: ShortcutStroke(key: "k", command: true, shift: true))
        let chord = StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "c"))
        let candidates: [StoredShortcut?] = [nil, .unbound, single, chord]
        for candidate in candidates {
            for hostDefault: StoredShortcut? in [nil, .unbound, single, chord] {
                var normalizations = 0
                var conflicts = 0
                #expect(action.effectivePersistedShortcut(candidate, defaultShortcut: hostDefault, normalizing: {
                    normalizations += 1
                    return $0
                }, conflictsWithReservedShortcut: { _ in
                    conflicts += 1
                    return false
                }) == nil)
                #expect(normalizations == 0)
                #expect(conflicts == 0)
                #expect(action.effectivePersistedShortcut(candidate, defaultShortcut: hostDefault, conflictsWithReservedShortcut: { _ in
                    conflicts += 1
                    return false
                }) == nil)
                #expect(conflicts == 0)
            }
        }
        #expect(action.defaultStroke == nil)
        #expect(action.defaultShortcut == nil)
        #expect(!ShortcutAction.settingsVisibleActions.contains(action))
    }

    @Test func historicalIdentifiersAndMetadataRemainIntact() {
        for (raw, name) in [("newCloudWorkspace", "New Cloud Workspace"), ("newCloudMachine", "New Cloud Machine")] {
            let action = ShortcutAction(rawValue: raw)
            #expect(action?.rawValue == raw)
            #expect(action?.isRetired == true)
            #expect(action?.displayName == name)
            #expect(action?.group == .workspace)
            #expect(ShortcutAction.allCases.contains { $0.rawValue == raw })
        }
        #expect(Set(ShortcutAction.allCases.filter(\.isRetired)) == Set([.newCloudWorkspace, .newCloudMachine]))
    }

    @Test(arguments: [ShortcutAction.newTab, .newBrowserWorkspace, .newSurface])
    func localBindingsRemainAvailable(action: ShortcutAction) {
        #expect(!action.isRetired)
        #expect(action.defaultShortcut != nil)
        #expect(ShortcutAction.settingsVisibleActions.contains(action))
        #expect(action.effectivePersistedShortcut(nil) == action.defaultShortcut)
        let candidate = StoredShortcut(first: ShortcutStroke(key: "k", command: true, shift: true))
        #expect(action.effectivePersistedShortcut(candidate) == candidate)
        #expect(action.effectivePersistedShortcut(candidate, normalizing: { $0 }, conflictsWithReservedShortcut: { _ in false }) == candidate)
    }
}
