import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport

/// Immutable state that determines the native terminal picker's presented menu.
struct TerminalPickerMenuValue: Equatable {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let selectedMacSurfaceID: MobileSurfacePreview.ID?
    let selectedName: String?
    let canCreateWorkspace: Bool
    /// False for workspaces without terminal tabs (plain SSH shells).
    let canCreateTerminal: Bool
    /// SSH tmux and cmux-tui workspaces: terminals grouped by tmux window or
    /// cmux-tui screen (PRD D32). `nil` keeps the flat Terminals section
    /// (Mac workspaces, shells).
    let sshTabLayout: MobileSSHTabLayout?
    init(
        liveTerminals: [MobileTerminalPreview],
        liveSurfaces: [MobileSurfacePreview] = [],
        selectedID: MobileTerminalPreview.ID?,
        selectedMacSurfaceID: MobileSurfacePreview.ID? = nil,
        canCreateWorkspace: Bool,
        canCreateTerminal: Bool = true,
        sshTabLayout: MobileSSHTabLayout? = nil
    ) {
        let resolvedRows = liveTerminals.map(TerminalPickerMenuRow.init)
            + liveSurfaces.filter { $0.kind.isSelectableMacSurface }.map(TerminalPickerMenuRow.init)
        rows = resolvedRows
        let selection = resolvedRows.resolvedTerminalPickerSelection(selectedID: selectedID)
        self.selectedID = selection?.id
        self.selectedMacSurfaceID = selectedMacSurfaceID
        selectedName = selectedMacSurfaceID.flatMap { id in
            resolvedRows.first(where: { $0.id == .macSurface(id) })?.name
        } ?? selection?.name
        self.canCreateWorkspace = canCreateWorkspace
        self.canCreateTerminal = canCreateTerminal
        self.sshTabLayout = sshTabLayout
    }

    /// The selected surface row, falling back to the resolved terminal.
    var checkedRowID: TerminalPickerMenuRow.ID? {
        if let selectedMacSurfaceID,
           rows.contains(where: { $0.id == .macSurface(selectedMacSurfaceID) }) {
            return .macSurface(selectedMacSurfaceID)
        }
        return selectedID.map(TerminalPickerMenuRow.ID.terminal)
    }

    var terminalRows: [TerminalPickerMenuRow] {
        rows.filter { if case .terminal = $0.id { true } else { false } }
    }

    /// Selectable non-terminal surfaces; retired kinds are excluded above.
    var macSurfaceRows: [TerminalPickerMenuRow] {
        rows.filter { if case .macSurface = $0.id { true } else { false } }
    }
}
