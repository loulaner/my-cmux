#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

/// Immutable menu content, built only when UIKit asks to present the picker.
@MainActor
struct TerminalPickerMenuContent {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions

    func makeElements() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        if let layout = value.sshTabLayout {
            sections.append(contentsOf: groupedTerminalSections(layout))
        } else {
            sections.append(UIMenu(
                title: L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"),
                options: .displayInline,
                children: value.terminalRows.compactMap { terminal in
                    guard let id = terminal.terminalID else { return nil }
                    return action(
                        terminal.name, image: "terminal",
                        identifier: "MobileTerminalMenuItem-\(id.rawValue)",
                        checked: terminal.id == value.checkedRowID
                    ) { actions.selectTerminal(id) }
                }
            ))
        }

        if !value.macSurfaceRows.isEmpty {
            sections.append(UIMenu(
                title: L10n.string("mobile.surface.section", defaultValue: "Mac Surfaces"),
                options: .displayInline,
                children: value.macSurfaceRows.compactMap { surface in
                    guard let id = surface.macSurfaceID else { return nil }
                    return action(
                        surface.name, image: surface.surfaceKind.systemImage,
                        identifier: "MobileMacSurfaceMenuItem-\(id.rawValue)",
                        checked: surface.id == value.checkedRowID
                    ) { actions.selectMacSurface(id) }
                }
            ))
        }

        var creationActions = [action(
            L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
            image: "plus.square.on.square", identifier: "MobileNewWorkspaceMenuItem",
            enabled: value.canCreateWorkspace, handler: actions.createWorkspace
        )]
        if value.canCreateTerminal {
            creationActions.append(action(
                value.sshTabLayout?.newTerminalTitle
                    ?? L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                image: "plus", identifier: "MobileNewTerminalMenuItem", handler: actions.createTerminal
            ))
        }
        sections.append(UIMenu(options: .displayInline, children: creationActions))

        var utilityActions: [UIAction] = []
        utilityActions.append(action(
            L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
            image: "doc.plaintext", identifier: "MobileViewAsTextMenuItem", handler: actions.openTextSheet
        ))
        #if DEBUG
        utilityActions.append(action(
            L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
            image: "doc.on.clipboard", identifier: "MobileCopyDebugLogsMenuItem", handler: actions.copyDebugLogs
        ))
        #endif
        utilityActions.append(action(
            L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
            image: "paperplane", identifier: "MobileSendFeedbackMenuItem", handler: actions.sendFeedback
        ))
        sections.append(UIMenu(options: .displayInline, children: utilityActions))
        return sections
    }

    private func groupedTerminalSections(_ layout: MobileSSHTabLayout) -> [UIMenuElement] {
        layout.sections.map { section in
            var panes: [UIMenuElement] = []
            var children: [UIMenuElement] = []
            for row in section.rows {
                if row.startsPane, !children.isEmpty {
                    panes.append(UIMenu(options: .displayInline, children: children))
                    children = []
                }
                let id = MobileTerminalPreview.ID(rawValue: row.id)
                children.append(action(
                    row.title, subtitle: row.paneLabel, image: "terminal",
                    identifier: "MobileTerminalMenuItem-\(row.id)",
                    checked: value.checkedRowID == .terminal(id)
                ) { actions.selectTerminal(id) })
            }
            children.append(contentsOf: section.actions.map { sectionAction in
                action(
                    sectionAction.title, image: sectionAction.systemImage,
                    identifier: sectionAction.accessibilityIdentifier(section: section.id)
                ) { actions.createSSHTab(section.id, sectionAction) }
            })
            if !panes.isEmpty {
                panes.append(UIMenu(options: .displayInline, children: children))
                children = panes
            }
            return UIMenu(title: section.title, options: .displayInline, children: children)
        }
    }

    private func action(
        _ title: String,
        subtitle: String? = nil,
        image: String,
        identifier: String,
        checked: Bool = false,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> UIAction {
        let action = UIAction(
            title: title,
            subtitle: subtitle,
            image: UIImage(systemName: image),
            identifier: UIAction.Identifier(identifier),
            attributes: enabled ? [] : .disabled,
            state: checked ? .on : .off
        ) { _ in handler() }
        action.accessibilityIdentifier = identifier
        return action
    }
}
#endif
