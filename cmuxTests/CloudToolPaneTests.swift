import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Whole Cloud tool panes", .serialized)
struct CloudToolPaneTests {
    private func withCloudEnabled<T>(_ body: () throws -> T) rethrows -> T {
        let key = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        return try body()
    }

    @Test("Retired Cloud creation and reuse refuse without adding a panel")
    func cloudToolCreationAndReuse() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try withCloudEnabled {
                let fixture = try VaultPaneAppFixture()
                defer { fixture.tearDown() }
                let workspace = fixture.workspace
                let pane = try #require(workspace.bonsplitController.allPaneIds.first)
                let originalPanels = Set(workspace.panels.keys)
                #expect(workspace.newRightSidebarToolSurface(inPane: pane, mode: .machines, focus: false) == nil)
                #expect(workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: .machines, focus: false) == nil)
                #expect(Set(workspace.panels.keys) == originalPanels)
                for mode in [RightSidebarMode.files, .sessions] {
                    let panel = try #require(workspace.newRightSidebarToolSurface(inPane: pane, mode: mode, focus: false))
                    #expect(workspace.openOrFocusRightSidebarToolSurface(inPane: pane, mode: mode, focus: false) === panel)
                }
            }
        }
    }

    @Test("Historical Cloud snapshot restores its metadata and snapshots again")
    func historicalCloudToolRestoration() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try VaultPaneAppFixture()
            defer { fixture.tearDown() }
            let pane = try #require(fixture.workspace.bonsplitController.allPaneIds.first)
            let files = try #require(fixture.workspace.newRightSidebarToolSurface(inPane: pane, mode: .files, focus: false))
            var snapshot = fixture.manager.sessionSnapshot(includeScrollback: false)
            let wi = try #require(snapshot.workspaces.firstIndex { $0.panels.contains { $0.id == files.id } })
            let pi = try #require(snapshot.workspaces[wi].panels.firstIndex { $0.id == files.id })
            snapshot.workspaces[wi].panels[pi].rightSidebarTool = SessionRightSidebarToolPanelSnapshot(mode: .machines)
            snapshot.workspaces[wi].panels[pi].customTitle = "Historical Cloud"
            snapshot.workspaces[wi].panels[pi].isPinned = true
            let decoded = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: JSONEncoder().encode(snapshot))
            let restored = TabManager(autoWelcomeIfNeeded: false)
            defer { restored.tabs.forEach { $0.teardownAllPanels() } }
            restored.restoreSessionSnapshot(decoded)
            let workspace = try #require(restored.tabs.first { $0.panels.values.contains { ($0 as? RightSidebarToolPanel)?.mode == .machines } })
            let cloud = try #require(workspace.panels.values.compactMap { $0 as? RightSidebarToolPanel }.first { $0.mode == .machines })
            #expect(cloud.displayTitle == RightSidebarMode.machines.label)
            let before = Set(workspace.panels.keys)
            let restoredPane = try #require(workspace.bonsplitController.allPaneIds.first)
            #expect(workspace.openOrFocusRightSidebarToolSurface(inPane: restoredPane, mode: .machines) == nil)
            #expect(Set(workspace.panels.keys) == before)
            let saved = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == cloud.id })
            #expect(saved.rightSidebarTool?.mode == .machines)
            #expect(saved.customTitle == "Historical Cloud")
            #expect(saved.isPinned)
        }
    }

    @Test("The palette offers Files and Vault but not retired Cloud")
    func cloudToolPaletteContribution() {
        let descriptors = withCloudEnabled {
            ContentView.commandPaletteRightSidebarToolPaneCommandDescriptors()
        }
        #expect(!descriptors.contains { $0.mode == .machines })
        #expect(descriptors.contains { $0.mode == .files })
        #expect(descriptors.contains { $0.mode == .sessions })
    }
}
