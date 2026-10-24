import CmuxAuthRuntime

extension AppDelegate {
    func configureWorkspacePresence(auth: AuthCoordinator) {
        workspacePresenceController.configure(auth: auth)
    }
}
