/// Single-record storage; callers never persist a connection draft or partial capability.
public protocol MobileLocalDirectClientStoring: Sendable {
    /// Returns nil only when no saved record exists; corrupt records must throw.
    func load() async throws -> MobileLocalDirectClientRecord?
    /// Atomically stores a validated record before the UI reports it as remembered.
    func save(_ record: MobileLocalDirectClientRecord) async throws
    /// Removes only this client's local record, not the Mac's authorization.
    func forget() async throws
}
