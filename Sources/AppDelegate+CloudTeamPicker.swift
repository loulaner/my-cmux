import CmuxCloud
import AppKit
import CmuxSettingsUI

extension AppDelegate {
    @MainActor
    func handleCloudTeamPickerShortcut(_ event: NSEvent) -> Bool {
        guard matchConfiguredShortcut(event: event, action: .openTeamPicker) else { return false }
        _ = openCloudTeamPicker(
            preferredWindow: event.window ?? shortcutRoutingActiveWindow,
            debugSource: "shortcut.openTeamPicker"
        )
        return true
    }

    /// Navigates to Account settings, where the existing Active Team picker lives.
    @MainActor
    @discardableResult
    func openCloudTeamPicker(
        preferredWindow: NSWindow? = nil,
        debugSource: String
    ) -> Bool {
        guard CloudMachinesFeature.isEnabled else {
            let alert = NSAlert()
            alert.messageText = String(localized: "command.auth.teamPicker.title", defaultValue: "Open Team Picker")
            alert.informativeText = CloudMachinesFeature.disabledMessage
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            if let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return false
        }

        SettingsWindowPresenter.show(navigationTarget: .account)
        SettingsNavigationRequest.post(.account, anchorID: "setting:account:account", highlight: true)
#if DEBUG
        cmuxDebugLog("cloud.teamPicker.open source=\(debugSource)")
#endif
        return true
    }

    /// Opens the existing invitation composer in Account settings.
    @MainActor
    @discardableResult
    func openCloudTeamInvite(preferredWindow: NSWindow? = nil, debugSource: String) -> Bool {
        guard CloudMachinesFeature.isEnabled,
              let flow = auth?.accountFlow,
              flow.isAuthenticated, flow.confirmedTeamID != nil else {
            NSSound.beep()
            return false
        }
        flow.showTeamMembers(focusInvite: true)
#if DEBUG
        cmuxDebugLog("cloud.teamInvite.open source=\(debugSource)")
#endif
        return true
    }
}
