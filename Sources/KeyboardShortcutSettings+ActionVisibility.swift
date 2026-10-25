import CmuxSettings

extension KeyboardShortcutSettings.Action {
    var isRetiredShortcutAction: Bool {
        CmuxSettings.ShortcutAction(rawValue: rawValue)?.isRetired ?? false
    }

    /// Whether this action is part of the public, user-configurable shortcut catalog.
    var isPublicShortcutAction: Bool {
        guard !isRetiredShortcutAction else { return false }
        switch self {
        case .switchRightSidebarToFiles,
             .switchRightSidebarToFind,
             .switchRightSidebarToSessions,
             .switchRightSidebarToFeed,
             .switchRightSidebarToDock,
             .switchRightSidebarToMachines:
            return false
        default:
            return true
        }
    }
}
