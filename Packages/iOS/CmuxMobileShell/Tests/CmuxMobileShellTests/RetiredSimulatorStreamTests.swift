import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct RetiredSimulatorStreamTests {
    @Test func retiredTabFallsBackWithoutChangingBytesAcrossRefreshAndReopen() async throws {
        let fixture = try RetiredSimulatorStreamFixture()
        defer { fixture.cleanDefaults() }
        for _ in 0..<3 {
            await fixture.store.openWorkspace(fixture.workspace.id)
            fixture.store.replaceForegroundWorkspaceState([fixture.workspace])
            fixture.store.refreshWorkspaceSelection()
            #expect(fixture.store.selectedTerminalID == "terminal-1")
            #expect(fixture.store.selectedMacSurfaceID == nil)
            #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
            fixture.expectUnchangedMemory()
        }
        // The wire surface is retained as unsupported, never reclassified as a terminal.
        #expect(fixture.workspace.surfaces.first?.kind == .other("simulator"))
        #expect(fixture.workspace.focusedNonTerminalSurface == nil)
        fixture.store.selectMacSurface("sim-1")
        #expect(fixture.store.selectedMacSurfaceID == nil)
        fixture.expectUnchangedMemory()
        try await fixture.expectNoSimulatorRequests()
    }

    @Test func activeBrowserCannotOverwriteRetiredTabMemory() async throws {
        let fixture = try RetiredSimulatorStreamFixture()
        defer { fixture.cleanDefaults() }
        fixture.browser.replacePanels(in: "workspace-1", with: [MobileBrowserPanelDescriptor(
            panelID: "browser-1", workspaceID: "workspace-1", url: nil, title: "Browser",
            pageWidth: 800, pageHeight: 600, canGoBack: false, canGoForward: false, isLoading: false
        )])
        _ = fixture.browser.activate(panelID: "browser-1", in: "workspace-1")
        await fixture.store.openWorkspace(fixture.workspace.id)
        fixture.store.refreshWorkspaceSelection()
        #expect(fixture.browser.activeState(in: "workspace-1")?.id == "browser-1")
        #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
        fixture.expectUnchangedMemory()
        try await fixture.expectNoSimulatorRequests()
    }

    @Test func noTerminalDisarmsWithoutInventingASurfaceOrStartingAStream() async throws {
        let fixture = try RetiredSimulatorStreamFixture(hasTerminal: false)
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        #expect(fixture.store.selectedTerminalID == nil)
        #expect(fixture.store.selectedMacSurfaceID == nil)
        #expect(fixture.workspace.selectedMacSurface(id: "sim-1") == nil)
        #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
        fixture.expectUnchangedMemory()
        try await fixture.expectNoSimulatorRequests()
    }

    @Test func explicitlyPickingTheSameFallbackTerminalReplacesMemory() async throws {
        let fixture = try RetiredSimulatorStreamFixture()
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        #expect(fixture.store.selectedTerminalID == "terminal-1")
        fixture.expectUnchangedMemory()
        fixture.store.selectTerminalFromChrome("terminal-1")
        #expect(fixture.persistedTab == MobileWorkspaceLastTab(kind: .terminal, tabID: "terminal-1"))
        #expect(fixture.defaults.data(forKey: MobileWorkspaceLastTabStore.defaultsKey) != fixture.originalBytes)
        try await fixture.expectNoSimulatorRequests()
    }

    @Test func missingSupportedTerminalStillRecordsItsFallback() async throws {
        let fixture = try RetiredSimulatorStreamFixture(remembered: .init(kind: .terminal, tabID: "missing"))
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        #expect(fixture.store.selectedTerminalID == "terminal-1")
        #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
        #expect(fixture.persistedTab == MobileWorkspaceLastTab(kind: .terminal, tabID: "terminal-1"))
    }

    @Test func undiscoveredSupportedBrowserStillWaitsWithoutOverwritingMemory() async throws {
        let fixture = try RetiredSimulatorStreamFixture(remembered: .init(kind: .browserStream, tabID: "not-discovered"))
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        #expect(fixture.store.selectedTerminalID == "terminal-1")
        #expect(fixture.store.pendingLastTabRestoreWorkspaceID == fixture.workspace.id)
        fixture.expectUnchangedMemory()
        try await fixture.expectNoSimulatorRequests()
    }

    @Test func unhydratedSupportedTerminalStillWaits() async throws {
        let fixture = try RetiredSimulatorStreamFixture(
            remembered: .init(kind: .terminal, tabID: "not-hydrated"),
            hasTerminal: false, hasSimulatorSurface: false
        )
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        #expect(fixture.store.selectedTerminalID == nil)
        #expect(fixture.store.pendingLastTabRestoreWorkspaceID == fixture.workspace.id)
        fixture.expectUnchangedMemory()
    }

}
