// Only dependencies are spies; the complete production handler follows below.
import Darwin
/*__PREVIEW__*/
/*__PREVIEW_ERROR__*/
/*__FRAME__*/

@MainActor final class MobileWorkspaceFilePreviewService {
    static var calls = 0
    static var roots: [String] = []
    static var requests: [(String, String)] = []
    static var started: (() -> Void)?
    static var continuation: CheckedContinuation<MobileWorkspaceFilePreview, any Error>?
    static var initializationError: (any Error)?
    init(rootDirectory: URL) throws {
        Self.calls += 1; Self.roots.append(rootDirectory.path)
        if let error = Self.initializationError { throw error }
    }
    func read(relativePath: String, expectedRootID: String) async throws -> MobileWorkspaceFilePreview {
        Self.requests.append((relativePath, expectedRootID))
        return try await withCheckedThrowingContinuation {
            Self.continuation = $0; Self.started?()
        }
    }
}
/*__LEAF__*/

@main @MainActor struct Harness {
    static var assertions = 0
    static var failures = 0
    static let identifier = UUID(uuidString: "2B6D9163-FE8B-44B1-8509-2A62D96688E9")!
    static let rootID = String(repeating: "a", count: 64)
    static let path = "literal%2e%2e/~/e\u{301}"
    static let bytes = Data("SYNTHETIC_PREVIEW_BYTES".utf8)
    static var params: [String: Any] { ["workspace_id": identifier.uuidString.lowercased(), "path": path, "root_id": rootID] }
    static func check(_ value: @autoclosure () -> Bool, _ label: String = "assertion", line: UInt = #line) {
        assertions += 1
        if !value() { failures += 1; print("FAIL \(label) at \(line)") }
    }
    static func reset() {
        ManagedFileTransferPolicy.state.withLock { $0 = false }
        MobileWorkspaceFilePreviewService.calls = 0
        MobileWorkspaceFilePreviewService.roots = []
        MobileWorkspaceFilePreviewService.requests = []
        MobileWorkspaceFilePreviewService.started = nil
        MobileWorkspaceFilePreviewService.continuation = nil
        MobileWorkspaceFilePreviewService.initializationError = nil
    }
    static func balanced(_ quota: MobileTaskFilesystemJobQuota) {
        check(quota.acquire(), "acquired slot released")
        check(!quota.acquire(), "other job slot not released")
        quota.release(); quota.release()
    }
    static func error(_ result: TerminalController.V2CallResult, _ expected: String) {
        guard case let .err(code, message, data) = result else {
            if case let .ok(payload) = result, let object = payload as? [String: Any],
               let base64 = object["data_base64"] as? String, Data(base64Encoded: base64) == bytes {
                check(false, "leaked SYNTHETIC_PREVIEW_BYTES")
            }
            check(false, "expected refusal \(expected)"); return
        }
        check(code == expected, "code \(expected)")
        check(data == nil && !message.contains("SECRET") && !message.contains("/fixture"), "safe error")
        if code == "file_transfer_disabled" { check(message == ManagedFileTransferPolicy.disabledMessage) }
    }
    static func immediate(_ expected: String, auth: MobileHostConnectionAuthorizationContext? = .localDirect,
                          request: [String: Any]? = nil, configure: (TerminalController) -> Void = { _ in }) async {
        reset()
        let controller = TerminalController(identifier); let quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire()); configure(controller)
        let result = await controller.v2MobileWorkspaceFilePreview(params: request ?? params, authorization: auth, filesystemJobQuota: quota)
        error(result, expected)
        check(MobileWorkspaceFilePreviewService.calls == 0 && MobileWorkspaceFilePreviewService.requests.isEmpty, "no I/O before admission")
        if expected != "workspace_not_found" && expected != "unsupported_workspace" && expected != "workspace_unavailable" { check(controller.lookups == 0, "no routing before trust/parser") }
        balanced(quota)
    }
    static func preview(data: Data = bytes, total: Int64? = nil, truncated: Bool = false,
                        path: String = path, marker: String = rootID) -> MobileWorkspaceFilePreview {
        MobileWorkspaceFilePreview(relativePath: path, rootID: marker, data: data, totalBytes: total ?? Int64(data.count), truncated: truncated)
    }
    static func suspended(_ mode: String, value: MobileWorkspaceFilePreview? = nil,
                          failure: (any Error)? = nil, expected: String? = nil) async {
        reset()
        let controller = TerminalController(identifier); let quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire())
        let (events, signal) = AsyncStream<Void>.makeStream()
        MobileWorkspaceFilePreviewService.started = { signal.yield(()) }
        let task = Task { @MainActor in
            controller.last = await controller.v2MobileWorkspaceFilePreview(params: params, authorization: .localDirect, filesystemJobQuota: quota)
        }
        var iterator = events.makeAsyncIterator(); _ = await iterator.next()
        check(MobileWorkspaceFilePreviewService.calls == 1)
        check(MobileWorkspaceFilePreviewService.roots == ["/fixture-authorized-root"])
        check(MobileWorkspaceFilePreviewService.requests.first?.0.utf8.elementsEqual(path.utf8) == true)
        check(MobileWorkspaceFilePreviewService.requests.first?.1 == rootID)
        check(!quota.acquire(), "shared slots held while awaiting")
        switch mode {
        case "mdm", "mdm-error", "mdm-cancel": ManagedFileTransferPolicy.state.withLock { $0 = true }
        case "replace": controller.workspace = Workspace(identifier)
        case "remove": controller.workspace = nil
        case "cwd": controller.workspace?.presentedCurrentDirectory = "/other"
        case "remote": controller.workspace?.usesRemoteDirectoryProvenance = true
        default: break
        }
        if mode == "cancel" || mode == "mdm-cancel" { task.cancel() }
        let continuation = MobileWorkspaceFilePreviewService.continuation
        MobileWorkspaceFilePreviewService.continuation = nil
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: value ?? preview()) }
        await task.value
        guard let result = controller.last else { check(false, "missing result"); return }
        signal.finish()
        if let expected { error(result, expected) }
        else if case let .ok(raw) = result, let payload = raw as? [String: Any] {
            let expected = value ?? preview()
            check(Set(payload.keys) == ["workspace_id", "path", "root_id", "data_base64", "byte_count", "total_bytes", "truncated"])
            check(payload["workspace_id"] as? String == identifier.uuidString)
            check((payload["path"] as? String)?.utf8.elementsEqual(path.utf8) == true)
            check(payload["root_id"] as? String == rootID)
            check(payload["data_base64"] as? String == expected.data.base64EncodedString(), "standard padded base64")
            check(Data(base64Encoded: payload["data_base64"] as? String ?? "!") == expected.data, "raw bytes")
            check(payload["byte_count"] as? Int == expected.data.count)
            check(payload["total_bytes"] as? Int64 == expected.totalBytes)
            check(payload["truncated"] as? Bool == expected.truncated)
        } else { check(false, "expected success") }
        balanced(quota)
    }
    static func main() async throws {
        for auth: MobileHostConnectionAuthorizationContext? in [nil, .stackBearer, .irohAdmission] {
            await immediate("method_not_found", auth: auth)
        }
        await immediate("file_transfer_disabled", request: [:]) { _ in ManagedFileTransferPolicy.state.withLock { $0 = true } }
        await immediate("invalid_params", request: [:])
        for key in ["auth", "offset", "max_bytes", "absolute_path"] {
            var request = params; request[key] = "forged"
            await immediate("invalid_params", request: request)
        }
        await immediate("workspace_not_found") { $0.workspace = nil }
        await immediate("unsupported_workspace") { $0.workspace?.usesRemoteDirectoryProvenance = true }
        for directory: String? in [nil, "relative", "/bad\0", "/" + String(repeating: "x", count: 4096)] {
            await immediate("workspace_unavailable") { $0.workspace?.presentedCurrentDirectory = directory }
        }
        reset()
        let quota = MobileTaskFilesystemJobQuota(); check(quota.acquire()); check(quota.acquire())
        let controller = TerminalController(identifier)
        error(await controller.v2MobileWorkspaceFilePreview(params: params, authorization: .localDirect, filesystemJobQuota: quota), "busy")
        check(!quota.acquire() && MobileWorkspaceFilePreviewService.calls == 0, "busy must not release")
        quota.release(); balanced(quota)
        for mode in ["mdm", "mdm-cancel", "cancel", "replace", "remove", "cwd", "remote"] {
            await suspended(mode, expected: mode.hasPrefix("mdm") ? "file_transfer_disabled" : mode == "cancel" ? "cancelled" : "workspace_changed")
        }
        await suspended("mdm-error", failure: NSError(domain: "SECRET /fixture", code: 99), expected: "file_transfer_disabled")
        let mappings: [(any Error, String)] = [
            (MobileWorkspaceFilePreviewError.invalidRequest, "invalid_params"), (MobileWorkspaceFilePreviewError.invalidPath, "invalid_params"),
        ]
        for (failure, code) in mappings { await suspended("error", failure: failure, expected: code) }
        for (failure, code): (MobileWorkspaceFilePreviewError, String) in [
            (.rootChanged, "root_changed"), (.notFound, "file_not_found"), (.notRegularFile, "not_a_file"),
            (.permissionDenied, "permission_denied"), (.fileChanged, "file_changed"), (.unreadable, "unavailable")
        ] { await suspended("error", failure: failure, expected: code) }
        await suspended("error", failure: CancellationError(), expected: "cancelled")
        await suspended("error", failure: NSError(domain: "SECRET /fixture", code: 99), expected: "unavailable")
        reset(); let initQuota = MobileTaskFilesystemJobQuota(); check(initQuota.acquire())
        MobileWorkspaceFilePreviewService.initializationError = MobileWorkspaceFilePreviewError.invalidPath
        error(await TerminalController(identifier).v2MobileWorkspaceFilePreview(params: params, authorization: .localDirect, filesystemJobQuota: initQuota), "invalid_params")
        check(MobileWorkspaceFilePreviewService.requests.isEmpty); balanced(initQuota)
        for value in [preview(data: Data()), preview(data: Data([0, 255, 0xc3])), preview(),
                      preview(data: Data(repeating: 255, count: 262_144)),
                      preview(data: Data(repeating: 255, count: 262_144), total: Int64.max, truncated: true)] {
            await suspended("ok", value: value)
        }
        for value in [preview(path: "other"), preview(path: "literal%2e%2e/~/é"), preview(marker: String(repeating: "b", count: 64)),
                      preview(total: -1), preview(total: 100), preview(truncated: true),
                      preview(data: Data(repeating: 0, count: 262_145)),
                      preview(data: Data(repeating: 0, count: 262_144), total: 262_145, truncated: false)] {
            await suspended("invalid", value: value, expected: "unavailable")
        }
        // Worst escaping among legal path bytes, slash-heavy base64, ordinary UUID request id.
        let payload: [String: Any] = ["workspace_id": identifier.uuidString, "path": String(repeating: "\u{1}", count: 4096),
            "root_id": rootID, "data_base64": Data(repeating: 255, count: 262_144).base64EncodedString(),
            "byte_count": 262_144, "total_bytes": Int64.max, "truncated": true]
        let envelope = try JSONSerialization.data(withJSONObject: ["id": identifier.uuidString, "ok": true, "result": payload])
        check(envelope.count < MobileSyncFrameCodec.defaultMaximumFrameByteCount)
        var frame = try MobileSyncFrameCodec.encodeFrame(envelope)
        let decoded = try MobileSyncFrameCodec.decodeFrames(from: &frame)
        check(decoded == [envelope]); check(frame.isEmpty)
        print("framed envelope bytes=\(envelope.count); existing limit=\(MobileSyncFrameCodec.defaultMaximumFrameByteCount); arbitrary giant ids not promised")
        print("\(failures == 0 ? "PASS" : "FAIL") preview: \(assertions) assertions / \(failures) failures; spies, not real filesystem/auth/network")
        exit(failures == 0 ? 0 : 1)
    }
}
