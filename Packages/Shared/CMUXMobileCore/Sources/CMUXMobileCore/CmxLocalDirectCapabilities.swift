/// Narrow capabilities shared by local-direct clients and hosts.
// lint:allow -- Shared wire vocabulary used by both endpoints; retain the published String API without coupling it to either endpoint.
public enum CmxLocalDirectCapabilities {
    /// Reads the selected workspace's change list and text diffs only.
    /// Does not grant blob downloads, writes, or arbitrary-file access.
    public static let workspaceChangesRead = "workspace.changes.read.v1"
    /// Lists metadata beneath an explicitly authorized workspace directory only.
    /// Does not grant content reads, downloads, uploads, writes, or arbitrary absolute paths.
    public static let workspaceFilesList = "workspace.files.list.v1"
}
