import CmuxCloud
import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    static let commandPaletteAuthSignInCommandId = "palette.auth.signIn"
    static let commandPaletteAuthSignOutCommandId = "palette.auth.signOut"
    static let commandPaletteAuthTeamPickerCommandId = "palette.auth.teamPicker"
    static let commandPaletteAuthTeamMembersCommandId = "palette.auth.teamMembers"

    static func commandPaletteAuthCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthSignInCommandId,
                title: constant(String(localized: "command.auth.signIn.title", defaultValue: "Sign In")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["account", "auth", "authenticate", "authentication", "login", "log in", "signin", "sign in"],
                when: { context in
                    !context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthSignOutCommandId,
                title: constant(String(localized: "command.auth.signOut.title", defaultValue: "Sign Out")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["account", "auth", "logout", "log out", "signout", "sign out"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthTeamPickerCommandId,
                title: constant(String(localized: "command.auth.teamPicker.title", defaultValue: "Open Team Picker")),
                subtitle: constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud")),
                keywords: ["account", "auth", "team", "teams", "switch", "create"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthTeamMembersCommandId,
                title: constant(String(localized: "command.auth.teamMembers.title", defaultValue: "Invite Team Members")),
                subtitle: constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud")),
                keywords: ["account", "auth", "team", "teams", "invite", "members", "roster", "seats"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
        ]
    }

    func registerAuthCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteAuthSignInCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signIn.invoke")
#endif
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            auth.accountFlow.startSignIn()
        }
        registry.register(commandId: Self.commandPaletteAuthSignOutCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signOut.invoke")
#endif
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                await auth.accountFlow.signOut()
            }
        }
        registry.register(commandId: Self.commandPaletteAuthTeamPickerCommandId) {
            _ = AppDelegate.shared?.openCloudTeamPicker(
                preferredWindow: tabManager.window,
                debugSource: "palette.auth.teamPicker"
            )
        }
        registry.register(commandId: Self.commandPaletteAuthTeamMembersCommandId) {
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            auth.accountFlow.showTeamInvite(preferredWindow: tabManager.window)
        }
    }
}

extension ContentView {
    // These IDs remain part of existing action routing and capability contracts;
    // retaining an ID does not register an executable Cloud palette command.
    static let commandPaletteCloudAvailabilityInfoCommandId = "palette.cloud.availabilityInfo"
    static let commandPaletteCloudForkCommandId = "palette.cloud.fork"
    static let commandPaletteCloudSnapshotCommandId = "palette.cloud.snapshot"
    static let commandPaletteCloudRestoreCommandId = "palette.cloud.restore"
    static let commandPaletteCloudPromoteTemplateCommandId = "palette.cloud.promoteTemplate"
    static let commandPaletteCloudStatusCommandId = "palette.cloud.status"
    static let commandPaletteCloudPortsCommandId = "palette.cloud.ports"
    static let commandPaletteCloudToolsCommandId = "palette.cloud.tools"
    static let commandPaletteCloudHandoffCommandId = "palette.cloud.handoff"
    static let commandPaletteCloudNewWorkspaceCommandId = "palette.cloud.newWorkspace"
    static let commandPaletteCloudNewMachineCommandId = "palette.cloud.newMachine"


    /// Builds the Cloud-context explanation for local-only palette actions.
    /// Keeping this as a normal command makes the availability explanation
    /// searchable and gives Cloud users a localized reason for omitted rows.
    static func commandPaletteCloudAvailabilityInfoContribution(
        locale: Locale = .current
    ) -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: commandPaletteCloudAvailabilityInfoCommandId,
            title: { _ in
                String(
                    localized: "command.cloudVM.availabilityInfo.title",
                    defaultValue: "Show Cloud command availability",
                    locale: locale
                )
            },
            subtitle: { _ in
                String(
                    localized: "command.cloudVM.availabilityInfo.subtitle",
                    defaultValue: "Cloud workspace",
                    locale: locale
                )
            },
            keywords: String(
                localized: "command.cloudVM.availabilityInfo.keywords",
                defaultValue: "cloud, workspace, availability, local, unavailable, actions",
                locale: locale
            )
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            when: { $0.bool(CommandPaletteContextKeys.workspaceIsCloud) }
        )
    }

    /// Registers only the local explanation of Cloud command availability.
    func registerCloudAvailabilityInfoHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        let commandWindow = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        registry.register(commandId: Self.commandPaletteCloudAvailabilityInfoCommandId) {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "command.cloudVM.availabilityInfo.alertTitle",
                defaultValue: "Some commands are local-only"
            )
            alert.informativeText = String(
                localized: "command.cloudVM.availabilityInfo.alertMessage",
                defaultValue: "Folder, simulator, local browser creation, directory search, and diff commands are available after selecting a local workspace. Cloud VM commands may be unavailable here."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            if let commandWindow {
                alert.beginSheetModal(for: commandWindow, completionHandler: nil)
            } else {
                NSSound.beep()
            }
        }
    }
}
