import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TerminalPickerMenuValueTests {
    @Test func viewportChurnDoesNotChangeMenuValueButTitlesAndMembershipDo() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Build")
        let baseline = menuValue(liveTerminals: [terminal])

        var titleOnlyTerminal = terminal
        titleOnlyTerminal.name = "Build output"
        let titleOnlyChange = menuValue(liveTerminals: [titleOnlyTerminal])

        var viewportOnlyTerminal = terminal
        viewportOnlyTerminal.viewportFit = MobileTerminalViewportFit(
            effective: MobileTerminalViewportSize(columns: 80, rows: 24),
            client: MobileTerminalViewportSize(columns: 100, rows: 30),
            isCurrentClientLimiting: false
        )
        let viewportOnlyChange = menuValue(liveTerminals: [viewportOnlyTerminal])

        let addedTerminal = MobileTerminalPreview(id: "terminal-2", name: "Tests")
        let membershipChange = menuValue(
            liveTerminals: [viewportOnlyTerminal, addedTerminal]
        )

        #expect(titleOnlyChange != baseline)
        #expect(viewportOnlyChange == baseline)
        #expect(membershipChange != baseline)
    }

    @Test func selectionIsResolvedFromTheRowsDisplayedByTheMenu() {
        let liveTerminals = [
            MobileTerminalPreview(id: "terminal-first", name: "First"),
            MobileTerminalPreview(id: "terminal-selected", name: "Selected"),
        ]

        let selected = menuValue(
            liveTerminals: liveTerminals,
            selectedID: "terminal-selected"
        )
        let staleSelection = menuValue(
            liveTerminals: liveTerminals,
            selectedID: "terminal-missing"
        )

        #expect(selected.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-selected"))
        #expect(selected.selectedName == "Selected")
        #expect(staleSelection.selectedID == MobileTerminalPreview.ID(rawValue: "terminal-first"))
        #expect(staleSelection.selectedName == "First")
    }

    @Test func valueUsesLiveRowsAndHandlesNoTerminals() {
        let liveTerminal = MobileTerminalPreview(id: "terminal-live", name: "Live")
        let firstOpen = menuValue(
            liveTerminals: [liveTerminal],
            selectedID: "missing"
        )
        let noTerminals = menuValue(liveTerminals: [], selectedID: "missing")

        #expect(firstOpen.rows == [TerminalPickerMenuRow(liveTerminal)])
        #expect(firstOpen.selectedID == liveTerminal.id)
        #expect(firstOpen.selectedName == liveTerminal.name)
        #expect(noTerminals.rows.isEmpty)
        #expect(noTerminals.selectedID == nil)
        #expect(noTerminals.selectedName == nil)
    }

    @Test func nonTerminalSurfacesAppearInTheirOwnRowsAndCanBeSelected() {
        let surface = MobileSurfacePreview(id: "surface-1", kind: .markdown, title: "README")
        let value = TerminalPickerMenuValue(
            liveTerminals: [MobileTerminalPreview(id: "terminal-1", name: "Shell")],
            liveSurfaces: [
                MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell"),
                surface,
            ],
            selectedID: "terminal-1",
            selectedMacSurfaceID: surface.id,
            canCreateWorkspace: true
        )
        #expect(value.terminalRows.count == 1)
        #expect(value.macSurfaceRows == [TerminalPickerMenuRow(surface)])
        #expect(value.selectedName == "README")
    }

    @Test func retiredSimulatorSurfaceIsNotAPickerRowOrATerminal() {
        let simulator = MobileSurfacePreview(id: "sim-1", kind: .init(rawValue: "simulator"), title: "Simulator")
        let markdown = MobileSurfacePreview(id: "readme", kind: .markdown, title: "README")
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Shell")
        let value = TerminalPickerMenuValue(
            liveTerminals: [terminal], liveSurfaces: [simulator, markdown],
            selectedID: terminal.id, selectedMacSurfaceID: simulator.id,
            canCreateWorkspace: true
        )
        #expect(value.terminalRows == [TerminalPickerMenuRow(terminal)])
        #expect(value.macSurfaceRows == [TerminalPickerMenuRow(markdown)])
        #expect(value.checkedRowID == .terminal(terminal.id))
        #expect(!simulator.kind.isTerminal)
        let simulatorOnly = TerminalPickerMenuValue(
            liveTerminals: [], liveSurfaces: [simulator], selectedID: nil,
            canCreateWorkspace: false
        )
        #expect(simulatorOnly.rows.isEmpty)
        #expect(simulatorOnly.selectedID == nil)
    }

    @Test func exactlyOneRowCarriesTheCheckmark() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "Shell")
        let surface = MobileSurfacePreview(id: "surface-1", kind: .todo, title: "Todos")
        func value(
            selectedMacSurfaceID: MobileSurfacePreview.ID?,
            liveSurfaces: [MobileSurfacePreview]? = nil
        ) -> TerminalPickerMenuValue {
            TerminalPickerMenuValue(
                liveTerminals: [terminal],
                liveSurfaces: liveSurfaces ?? [
                    MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell"),
                    surface,
                ],
                selectedID: terminal.id,
                selectedMacSurfaceID: selectedMacSurfaceID,
                canCreateWorkspace: true
            )
        }

        // Mac surface selected: its row is checked, the terminal row is not.
        #expect(value(selectedMacSurfaceID: surface.id).checkedRowID == .macSurface(surface.id))
        // No surface selection: the resolved terminal is checked.
        #expect(value(selectedMacSurfaceID: nil).checkedRowID == .terminal(terminal.id))
        // Stale surface selection (row gone) falls back to the terminal row.
        #expect(
            value(
                selectedMacSurfaceID: surface.id,
                liveSurfaces: [MobileSurfacePreview(id: "terminal-1", kind: .terminal, title: "Shell")]
            ).checkedRowID == .terminal(terminal.id)
        )
    }





    private func menuValue(
        liveTerminals: [MobileTerminalPreview],
        selectedID: MobileTerminalPreview.ID? = "terminal-1"
    ) -> TerminalPickerMenuValue {
        TerminalPickerMenuValue(
            liveTerminals: liveTerminals,
            selectedID: selectedID,
            canCreateWorkspace: true
        )
    }
    @Test func mixedMenuExcludesRetiredBrowsersButKeepsFilesAndMarkdown() {
        let kinds: [MobileSurfacePreview.Kind] = [.browser, .filePreview, .markdown, .extensionBrowser, .other("simulator")]
        let surfaces = kinds.map { MobileSurfacePreview(id: .init(rawValue: $0.rawValue), kind: $0, title: $0.rawValue) }
        let value = TerminalPickerMenuValue(
            liveTerminals: [MobileTerminalPreview(id: "terminal", name: "Shell")],
            liveSurfaces: surfaces, selectedID: "terminal", canCreateWorkspace: true
        )
        #expect(value.terminalRows.count == 1)
        #expect(value.macSurfaceRows.map(\.surfaceKind) == [.filePreview, .markdown, .extensionBrowser])
        #expect(value.checkedRowID == .terminal("terminal"))
    }
}
