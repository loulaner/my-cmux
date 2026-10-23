public import CmuxMobileRPC

/// Minimal list projection: no cloud metadata or nonterminal surfaces are exposed to the root.
public struct MobileLocalDirectWorkspace: Identifiable, Sendable {
    /// Existing workspace identity.
    public let id: String
    /// User-visible Mac workspace title.
    public let title: String
    /// Only existing terminal panels, in the server's order.
    public let terminals: [MobileSyncWorkspaceListResponse.Terminal]
    /// Filters the server DTO without creating or attaching a remote task.
    public init(_ workspace: MobileSyncWorkspaceListResponse.Workspace) {
        id = workspace.id; title = workspace.title
        let nonterminals = Set((workspace.surfaces ?? []).filter { $0.kind != "terminal" }.map(\.surfaceID))
        terminals = workspace.terminals.filter { !nonterminals.contains($0.id) }
    }
}
