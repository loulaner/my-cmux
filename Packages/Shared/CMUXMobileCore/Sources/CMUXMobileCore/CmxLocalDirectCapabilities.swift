/// Narrow capabilities shared by local-direct clients and hosts.
// lint:allow -- Shared wire vocabulary used by both endpoints; retain the published String API without coupling it to either endpoint.
public enum CmxLocalDirectCapabilities {
    /// Reads the selected workspace's change list and text diffs only.
    /// Does not grant blob downloads, writes, or arbitrary-file access.
    public static let workspaceChangesRead = "workspace.changes.read.v1"
    /// Lists metadata beneath an explicitly authorized workspace directory only.
    /// Does not grant content reads, downloads, uploads, writes, or arbitrary absolute paths.
    public static let workspaceFilesList = "workspace.files.list.v1"
    /// Reads a fixed bounded raw prefix beneath an explicitly authorized workspace root.
    /// Does not grant streams, ranges, unbounded downloads, uploads, writes or absolute-path access.
    public static let workspaceFilesPreview = "workspace.files.preview.v1"
    /// Reads one complete file up to 2 MiB beneath an explicitly authorized workspace root.
    /// Does not grant ranges, streams, resume, unbounded downloads, uploads or writes.
    public static let workspaceFilesDownload = "workspace.files.download.v1"
    /// Complete new-file upload within an explicitly authorized workspace directory.
    public static let workspaceFilesUpload = "workspace.files.upload.v1"
}
