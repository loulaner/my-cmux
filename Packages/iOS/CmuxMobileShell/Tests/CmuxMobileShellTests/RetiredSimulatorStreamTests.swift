import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct RetiredSimulatorStreamTests {
    @Test(arguments: [MobileWorkspaceLastTab.Kind.simulatorStream, .browserStream, .localBrowser])
    func retiredTabFallsBackWithoutChangingBytesAcrossRefreshAndReopen(kind: MobileWorkspaceLastTab.Kind) async throws {
        let fixture = try RetiredSimulatorStreamFixture(remembered: .init(kind: kind, tabID: "sim-1"))
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


    @Test(arguments: [MobileWorkspaceLastTab.Kind.simulatorStream, .browserStream, .localBrowser])
    func noTerminalDisarmsWithoutInventingASurfaceOrStartingAStream(kind: MobileWorkspaceLastTab.Kind) async throws {
        let fixture = try RetiredSimulatorStreamFixture(remembered: .init(kind: kind, tabID: "sim-1"), hasTerminal: false)
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        #expect(fixture.store.selectedTerminalID == nil)
        #expect(fixture.store.selectedMacSurfaceID == nil)
        #expect(fixture.workspace.selectedMacSurface(id: "sim-1") == nil)
        #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
        fixture.expectUnchangedMemory()
        try await fixture.expectNoSimulatorRequests()
    }

    @Test(arguments: [MobileWorkspaceLastTab.Kind.simulatorStream, .browserStream, .localBrowser])
    func explicitlyPickingTheSameFallbackTerminalReplacesMemory(kind: MobileWorkspaceLastTab.Kind) async throws {
        let fixture = try RetiredSimulatorStreamFixture(remembered: .init(kind: kind, tabID: "sim-1"))
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

    @Test(arguments: [true, false])
    func knownBrowserMacSurfacePreservesMemory(hasTerminal: Bool) async throws {
        let fixture = try RetiredSimulatorStreamFixture(
            remembered: .init(kind: .macSurface, tabID: "browser-1"),
            hasTerminal: hasTerminal, hasBrowserSurface: true
        )
        defer { fixture.cleanDefaults() }
        for _ in 0..<3 {
            await fixture.store.openWorkspace(fixture.workspace.id)
            fixture.store.replaceForegroundWorkspaceState([fixture.workspace])
            fixture.store.refreshWorkspaceSelection()
            #expect(fixture.store.selectedMacSurfaceID == nil)
            #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
            fixture.expectUnchangedMemory()
        }
        fixture.store.selectMacSurface("browser-1")
        #expect(fixture.store.selectedMacSurfaceID == nil)
        fixture.expectUnchangedMemory()
        if hasTerminal {
            fixture.store.selectTerminalFromChrome("terminal-1")
            #expect(fixture.persistedTab == .init(kind: .terminal, tabID: "terminal-1"))
        }
    }

    @Test(arguments: [true, false])
    func missingMacSurfaceRetainsExistingHydrationSemantics(hasTerminal: Bool) async throws {
        let fixture = try RetiredSimulatorStreamFixture(
            remembered: .init(kind: .macSurface, tabID: "missing"),
            hasTerminal: hasTerminal, hasSimulatorSurface: false
        )
        defer { fixture.cleanDefaults() }
        await fixture.store.openWorkspace(fixture.workspace.id)
        if hasTerminal {
            #expect(fixture.store.pendingLastTabRestoreWorkspaceID == nil)
            #expect(fixture.persistedTab == .init(kind: .terminal, tabID: "terminal-1"))
        } else {
            #expect(fixture.store.pendingLastTabRestoreWorkspaceID == fixture.workspace.id)
            fixture.expectUnchangedMemory()
        }
    }

}
