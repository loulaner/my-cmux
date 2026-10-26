/// Narrow capabilities shared by local-direct clients and hosts.
public enum CmxLocalDirectCapabilities {
    /// Reads the selected workspace's change list and text diffs only.
    /// Does not grant blob downloads, writes, or arbitrary-file access.
    public static let workspaceChangesRead = "workspace.changes.read.v1"
}
