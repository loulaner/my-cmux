// Only dependencies are spies; the complete production handler follows below.
import Darwin
import CryptoKit
/*__DOWNLOAD__*/
/*__DOWNLOAD_ERROR__*/
/*__FRAME__*/

@MainActor final class MobileWorkspaceFileDownloadService {
    static let maximumDownloadBytes = 2_097_152
    static var calls = 0
    static var roots: [String] = []
    static var requests: [(String, String)] = []
    static var started: (() -> Void)?
    static var continuation: CheckedContinuation<MobileWorkspaceFileDownload, any Error>?
    static var initializationError: (any Error)?
    init(rootDirectory: URL) throws {
        Self.calls += 1; Self.roots.append(rootDirectory.path)
        if let error = Self.initializationError { throw error }
    }
    func read(relativePath: String, expectedRootID: String) async throws -> MobileWorkspaceFileDownload {
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
    static let bytes = Data("SYNTHETIC_DOWNLOAD_BYTES".utf8)
    static var params: [String: Any] { ["workspace_id": identifier.uuidString.lowercased(), "path": path, "root_id": rootID] }
    static func check(_ value: @autoclosure () -> Bool, _ label: String = "assertion", line: UInt = #line) {
        assertions += 1
        if !value() { failures += 1; print("FAIL \(label) at \(line)") }
    }
    static func reset() {
        ManagedFileTransferPolicy.state.withLock { $0 = false }
        MobileWorkspaceFileDownloadService.calls = 0
        MobileWorkspaceFileDownloadService.roots = []
        MobileWorkspaceFileDownloadService.requests = []
        MobileWorkspaceFileDownloadService.started = nil
        MobileWorkspaceFileDownloadService.continuation = nil
        MobileWorkspaceFileDownloadService.initializationError = nil
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
                check(false, "leaked SYNTHETIC_DOWNLOAD_BYTES")
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
        let result = await controller.v2MobileWorkspaceFileDownload(params: request ?? params, authorization: auth, filesystemJobQuota: quota)
        error(result, expected)
        check(MobileWorkspaceFileDownloadService.calls == 0 && MobileWorkspaceFileDownloadService.requests.isEmpty, "no I/O before admission")
        if expected != "workspace_not_found" && expected != "unsupported_workspace" && expected != "workspace_unavailable" { check(controller.lookups == 0, "no routing before trust/parser") }
        balanced(quota)
    }
    static func download(data: Data = bytes, path: String = path, marker: String = rootID,
                         digest: String? = nil) -> MobileWorkspaceFileDownload {
        MobileWorkspaceFileDownload(relativePath: path, rootID: marker, data: data,
            sha256: digest ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    static func suspended(_ mode: String, value: MobileWorkspaceFileDownload? = nil,
                          failure: (any Error)? = nil, expected: String? = nil) async {
        reset()
        let controller = TerminalController(identifier); let quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire())
        let (events, signal) = AsyncStream<Void>.makeStream()
        MobileWorkspaceFileDownloadService.started = { signal.yield(()) }
        let task = Task { @MainActor in
            controller.last = await controller.v2MobileWorkspaceFileDownload(params: params, authorization: .localDirect, filesystemJobQuota: quota)
        }
        var iterator = events.makeAsyncIterator(); _ = await iterator.next()
        check(MobileWorkspaceFileDownloadService.calls == 1)
        check(MobileWorkspaceFileDownloadService.roots == ["/fixture-authorized-root"])
        check(MobileWorkspaceFileDownloadService.requests.first?.0.utf8.elementsEqual(path.utf8) == true)
        check(MobileWorkspaceFileDownloadService.requests.first?.1 == rootID)
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
        let continuation = MobileWorkspaceFileDownloadService.continuation
        MobileWorkspaceFileDownloadService.continuation = nil
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: value ?? download()) }
        await task.value
        guard let result = controller.last else { check(false, "missing result"); return }
        signal.finish()
        if let expected { error(result, expected) }
        else if case let .ok(raw) = result, let payload = raw as? [String: Any] {
            let expected = value ?? download()
            check(Set(payload.keys) == ["workspace_id", "path", "root_id", "data_base64", "byte_count", "sha256"])
            check(payload["workspace_id"] as? String == identifier.uuidString)
            check((payload["path"] as? String)?.utf8.elementsEqual(path.utf8) == true)
            check(payload["root_id"] as? String == rootID)
            check(payload["data_base64"] as? String == expected.data.base64EncodedString(), "standard padded base64")
            check(Data(base64Encoded: payload["data_base64"] as? String ?? "!") == expected.data, "raw bytes")
            check(payload["byte_count"] as? Int == expected.data.count)
            check(payload["sha256"] as? String == expected.sha256)
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
        for key in ["workspace_id", "path", "root_id"] {
            var request = params; request.removeValue(forKey: key)
            await immediate("invalid_params", request: request)
            for value: Any in [NSNull(), true, 1, [], [:]] {
                request = params; request[key] = value
                await immediate("invalid_params", request: request)
            }
        }
        for value in ["", "/file", "a/../file", "a//file", "a/", "a\0b", String(repeating: "x", count: 4097)] {
            var request = params; request["path"] = value
            await immediate("invalid_params", request: request)
        }
        for value in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "é", count: 32)] {
            var request = params; request["root_id"] = value
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
        error(await controller.v2MobileWorkspaceFileDownload(params: params, authorization: .localDirect, filesystemJobQuota: quota), "busy")
        check(!quota.acquire() && MobileWorkspaceFileDownloadService.calls == 0, "busy must not release")
        quota.release(); balanced(quota)
        for mode in ["mdm", "mdm-cancel", "cancel", "replace", "remove", "cwd", "remote"] {
            await suspended(mode, expected: mode.hasPrefix("mdm") ? "file_transfer_disabled" : mode == "cancel" ? "cancelled" : "workspace_changed")
        }
        await suspended("mdm-error", failure: NSError(domain: "SECRET /fixture", code: 99), expected: "file_transfer_disabled")
        let mappings: [(any Error, String)] = [
            (MobileWorkspaceFileDownloadError.invalidRequest, "invalid_params"), (MobileWorkspaceFileDownloadError.invalidPath, "invalid_params"),
        ]
        for (failure, code) in mappings { await suspended("error", failure: failure, expected: code) }
        for (failure, code): (MobileWorkspaceFileDownloadError, String) in [
            (.rootChanged, "root_changed"), (.notFound, "file_not_found"), (.notRegularFile, "not_a_file"),
            (.permissionDenied, "permission_denied"), (.fileChanged, "file_changed"), (.tooLarge, "file_too_large"), (.unreadable, "unavailable")
        ] { await suspended("error", failure: failure, expected: code) }
        await suspended("error", failure: CancellationError(), expected: "cancelled")
        await suspended("error", failure: NSError(domain: "SECRET /fixture", code: 99), expected: "unavailable")
        reset(); let initQuota = MobileTaskFilesystemJobQuota(); check(initQuota.acquire())
        MobileWorkspaceFileDownloadService.initializationError = MobileWorkspaceFileDownloadError.invalidPath
        error(await TerminalController(identifier).v2MobileWorkspaceFileDownload(params: params, authorization: .localDirect, filesystemJobQuota: initQuota), "invalid_params")
        check(MobileWorkspaceFileDownloadService.requests.isEmpty); balanced(initQuota)
        for value in [download(data: Data()), download(data: Data([0, 255, 0xc3])), download(),
                      download(data: Data(repeating: 255, count: 2_097_152))] {
            await suspended("ok", value: value)
        }
        // Deliberately format-valid but incorrect digest: the handler does not hash on MainActor.
        // The real service hashes bytes; future clients must independently verify before export.
        await suspended("format-only", value: download(data: Data("abc".utf8), digest: String(repeating: "0", count: 64)))
        for value in [download(path: "other"), download(path: "literal%2e%2e/~/é"), download(marker: String(repeating: "b", count: 64)),
                      download(data: Data(repeating: 0, count: 2_097_153))] {
            await suspended("invalid", value: value, expected: "unavailable")
        }
        for digest in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                       String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                       String(repeating: "é", count: 32), String(repeating: "a", count: 63) + "\0"] {
            await suspended("invalid", value: download(digest: digest), expected: "unavailable")
        }
        // Worst escaping among legal path bytes, slash-heavy base64, ordinary UUID request id.
        let payload: [String: Any] = ["workspace_id": identifier.uuidString, "path": String(repeating: "\u{1}", count: 4096),
            "root_id": rootID, "data_base64": Data(repeating: 255, count: 2_097_152).base64EncodedString(),
            "byte_count": 2_097_152, "sha256": String(repeating: "a", count: 64)]
        let envelope = try JSONSerialization.data(withJSONObject: ["id": identifier.uuidString, "ok": true, "result": payload])
        check(envelope.count < MobileSyncFrameCodec.defaultMaximumFrameByteCount)
        var frame = try MobileSyncFrameCodec.encodeFrame(envelope)
        let decoded = try MobileSyncFrameCodec.decodeFrames(from: &frame)
        check(decoded == [envelope]); check(frame.isEmpty)
        print("framed envelope bytes=\(envelope.count); existing limit=\(MobileSyncFrameCodec.defaultMaximumFrameByteCount); arbitrary giant ids not promised")
        print("\(failures == 0 ? "PASS" : "FAIL") download: \(assertions) assertions / \(failures) failures; spies, not real filesystem/auth/network")
        exit(failures == 0 ? 0 : 1)
    }
}
