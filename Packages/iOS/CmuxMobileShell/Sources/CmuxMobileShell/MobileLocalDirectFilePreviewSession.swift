import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import Observation

/// Explicit bounded plain-text preview on a shared connection, without owning that connection.
///
/// Strict UTF-8 and control filtering decide displayability, not whether every file is binary or
/// visually trustworthy. BOM and format characters remain unchanged; no markup or ANSI is interpreted.
///
/// ```swift
/// let preview = try MobileLocalDirectFilePreviewSession(
///     rpc: rpc, workspaceID: workspaceID, connectionGeneration: generation,
///     path: path, rootID: rootID, capabilities: capabilities
/// )
/// preview.refresh()
/// ```
@MainActor @Observable
public final class MobileLocalDirectFilePreviewSession {
    /// Safe failures without raw server messages or content.
    public enum Failure: Error, Equatable, Sendable {
        /// The immutable selection is invalid.
        case invalidSelection
        /// The host does not support this operation.
        case unsupported
        /// The workspace is not local and eligible.
        case unsupportedWorkspace
        /// Policy or filesystem permissions deny access.
        case permissionDenied
        /// The selected workspace or file is unavailable.
        case fileUnavailable
        /// The workspace root changed.
        case directoryChanged
        /// Observable file metadata changed during reading.
        case fileChanged
        /// The object or bytes cannot be displayed as bounded plain text.
        case unsupportedContent
        /// The wire response is malformed or belongs to another selection.
        case invalidResponse
        /// An otherwise unclassified safe failure.
        case unavailable
        /// The connection or this session was retired.
        case disconnected
    }
    /// Readiness of this immutable selection.
    public enum LoadState: Equatable, Sendable {
        /// No current read, including an explicitly cancelled read.
        case idle
        /// A current explicit read is pending.
        case loading
        /// Validated text and metadata are available.
        case ready
        /// No content remains after a safe failure.
        case failed(Failure)
    }
    /// Original workspace spelling sent on the wire.
    public let workspaceID: String
    /// Immutable parent connection epoch.
    public let connectionGeneration: UInt64
    /// Original root-relative file path.
    public let path: String
    /// Required consistency marker, not permission to read arbitrary paths.
    public let rootID: String
    /// Strict, uninterpreted UTF-8 text; an empty file is the nonnil empty string.
    public private(set) var text: String?
    /// Host-observed full-file size, cleared on every failure.
    public private(set) var totalBytes: Int64?
    /// Bytes retained for display after any incomplete trailing sequence is removed.
    public private(set) var displayedByteCount = 0
    /// Whether the server returned a raw prefix shorter than the full file.
    public private(set) var truncated = false
    /// Current read readiness.
    public private(set) var state: LoadState = .idle
    @ObservationIgnored private let rpc: any MobileSyncing
    @ObservationIgnored private let workspaceUUID: UUID
    @ObservationIgnored private let capable: Bool
    @ObservationIgnored private var active = true
    @ObservationIgnored private var token: UInt64 = 0
    // Internal read-only completion handle for cancellation-ignoring test responses.
    @ObservationIgnored private(set) var requestTask: Task<Void, Never>?

    /// Captures a validated selection without connecting or issuing any request.
    /// - Parameters:
    ///   - rpc: Controller-owned shared RPC.
    ///   - workspaceID: Valid UUID spelling retained verbatim.
    ///   - connectionGeneration: Parent connection epoch.
    ///   - path: Nonempty, unmodified safe relative path.
    ///   - rootID: Required 64-byte lowercase hexadecimal root marker.
    ///   - capabilities: Capabilities advertised on this connection.
    /// - Throws: ``Failure/invalidSelection`` for an invalid identity, path or marker.
    public init(rpc: any MobileSyncing, workspaceID: String, connectionGeneration: UInt64,
                path: String, rootID: String, capabilities: Set<String>) throws {
        guard let uuid = UUID(uuidString: workspaceID), !path.isEmpty, path.utf8.count <= 4_096,
              !path.contains("\0"), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }), rootID.utf8.count == 64,
              rootID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidSelection }
        self.rpc = rpc; self.workspaceID = workspaceID; workspaceUUID = uuid
        self.connectionGeneration = connectionGeneration; self.path = path; self.rootID = rootID
        capable = capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesPreview)
    }

    deinit { requestTask?.cancel() }

    /// Replaces any pending read with one explicit request; never retries automatically.
    public func refresh() {
        guard active else { return }
        requestTask?.cancel(); requestTask = nil; token &+= 1; clearContent()
        guard capable else { state = .failed(.unsupported); return }
        state = .loading
        let token = token, rpc = rpc
        do {
            let request = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString,
                "method": "mobile.workspace.files.preview", "params": ["workspace_id": workspaceID, "path": path, "root_id": rootID]])
            requestTask = Task { [weak self] in
                guard self?.active == true, self?.token == token else { return }
                do {
                    let data = try await rpc.sendRequest(request, timeoutNanoseconds: nil)
                    guard let self, self.active, self.token == token else { return }
                    let preview = try MobileWorkspaceFilePreviewResponse.decode(data)
                    guard UUID(uuidString: preview.workspaceID) == self.workspaceUUID,
                          preview.path.utf8.elementsEqual(self.path.utf8), preview.rootID == self.rootID else {
                        throw Failure.invalidResponse
                    }
                    let display = try Self.displayText(preview.data, truncated: preview.truncated)
                    self.text = display.text; self.displayedByteCount = display.count
                    self.totalBytes = preview.totalBytes; self.truncated = preview.truncated; self.state = .ready
                } catch {
                    guard let self, self.active, self.token == token else { return }
                    self.clearContent()
                    if error is CancellationError { self.state = .idle }
                    else if case .rpcError("cancelled", _) = error as? MobileShellConnectionError { self.state = .idle }
                    else { self.state = .failed(Self.failure(error)) }
                }
            }
        } catch { clearContent(); state = .failed(.unavailable) }
    }

    /// Permanently clears this selection and cancels only its own request.
    public func invalidate() {
        guard active else { return }
        active = false; token &+= 1; requestTask?.cancel(); requestTask = nil
        clearContent(); state = .failed(.disconnected)
    }

    private func clearContent() { text = nil; totalBytes = nil; displayedByteCount = 0; truncated = false }

    /// Removes only a legal incomplete trailing UTF-8 prefix, never arbitrary invalid bytes.
    private static func displayText(_ data: Data, truncated: Bool) throws -> (text: String, count: Int) {
        var text = strictUTF8(data)
        var count = data.count
        if text == nil && truncated {
            let bytes = Array(data)
            for removed in 1...min(3, bytes.count) {
                let suffix = bytes.suffix(removed)
                guard incompleteUTF8(suffix) else { continue }
                if let candidate = strictUTF8(bytes.dropLast(removed)) {
                    text = candidate; count -= removed; break
                }
            }
        }
        guard let text, text.unicodeScalars.allSatisfy({
            $0.properties.generalCategory != .control || $0.value == 9 || $0.value == 10 || $0.value == 13
        }) else { throw Failure.unsupportedContent }
        return (text, count)
    }

    // The round trip rejects every repaired byte while preserving BOM/format scalars.
    // Foundation's encoding initializer strips a leading BOM; String(validating:as:)
    // is newer than this package's minimum OS versions.
    private static func strictUTF8<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8 {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }

    private static func incompleteUTF8(_ suffix: ArraySlice<UInt8>) -> Bool {
        guard let lead = suffix.first else { return false }
        let width: Int
        switch lead {
        case 0xC2...0xDF: width = 2
        case 0xE0...0xEF: width = 3
        case 0xF0...0xF4: width = 4
        default: return false
        }
        guard suffix.count < width, suffix.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { return false }
        if suffix.count > 1 {
            let second = suffix[suffix.index(after: suffix.startIndex)]
            if lead == 0xE0 && second < 0xA0 || lead == 0xED && second > 0x9F ||
                lead == 0xF0 && second < 0x90 || lead == 0xF4 && second > 0x8F { return false }
        }
        return true
    }

    private static func failure(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is DecodingError { return .invalidResponse }
        guard let error = error as? MobileShellConnectionError else { return .unavailable }
        switch error {
        case .connectionClosed: return .disconnected
        case .invalidResponse: return .invalidResponse
        case let .rpcError(code, _):
            switch code {
            case "invalid_params": return .invalidSelection
            case "method_not_found", "capability_disabled": return .unsupported
            case "unsupported_workspace": return .unsupportedWorkspace
            case "file_transfer_disabled", "forbidden", "permission_denied": return .permissionDenied
            case "root_changed", "workspace_changed": return .directoryChanged
            case "file_changed": return .fileChanged
            case "not_a_file": return .unsupportedContent
            case "file_not_found", "directory_not_found", "workspace_not_found", "workspace_unavailable": return .fileUnavailable
            case "admission_expired", "connection_closed", "disconnected": return .disconnected
            default: return .unavailable
            }
        default: return .unavailable
        }
    }
}
