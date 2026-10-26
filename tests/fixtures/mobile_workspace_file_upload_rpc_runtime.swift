// Actual context/handler/parser/policy/quota; controlled authorization payloads and actor service only.
import Darwin
import CryptoKit
struct CmxLocalDevice: Equatable, Sendable { let deviceID: String }
struct CmxIrohAdmittedPeer: Equatable, Sendable { let bindingID: String }
struct ChatArtifactLaneDescriptor: Sendable {}
actor MobileHostIrohArtifactTransferRegistry {
    enum Error: Swift.Error { case unavailable }
    func issue(canonicalPath: String, peer: CmxIrohAdmittedPeer) throws -> ChatArtifactLaneDescriptor { .init() }
}
/*__CONTEXT__*/
/*__UPLOAD__*/
/*__UPLOAD_ERROR__*/
/*__FRAME__*/

private actor Gate {
    private var entered = false, released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        let waiting = arrivals; arrivals.removeAll(); for waiter in waiting { waiter.resume() }
        if !released { await withCheckedContinuation { resume = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func open() { released = true; resume?.resume(); resume = nil }
}
private actor Admission {
    var allowed = true
    private(set) var calls = 0
    let gate: Gate?
    init(gate: Gate? = nil) { self.gate = gate }
    func validate() async -> Bool {
        calls += 1; let snapshot = allowed
        if let gate { await gate.pause() }
        return snapshot
    }
    func revoke() { allowed = false }
}
// Fixture-owned hooks only, not production injection or real disk publication.
@MainActor private enum Spy {
    static var stage = Gate(), post = Gate()
    static var calls = 0, published = 0
    static var root = "", directory = "", name = "", marker = "", digest = ""
    static var data = Data()
    static var failure: (any Error)?
    static var result: MobileWorkspaceFileUpload?
    static func record(_ root: String, _ directory: String, _ name: String, _ data: Data, _ marker: String, _ digest: String) {
        calls += 1; self.root = root; self.directory = directory; self.name = name; self.data = data; self.marker = marker; self.digest = digest
    }
    static func publish() { published += 1 }
    static func reset() {
        stage = Gate(); post = Gate(); calls = 0; published = 0; failure = nil; result = nil
        root = ""; directory = ""; name = ""; marker = ""; digest = ""; data = Data()
        ManagedFileTransferPolicy.state.withLock { $0 = false }
    }
}
actor MobileWorkspaceFileUploadService {
    let root: URL
    init(rootDirectory: URL) throws { root = rootDirectory }
    func write(relativeDirectoryPath: String, fileName: String, data: Data, expectedRootID: String, expectedSHA256: String,
               beforeCommit: @Sendable () async throws -> Void) async throws -> MobileWorkspaceFileUpload {
        await Spy.record(root.path(percentEncoded: false), relativeDirectoryPath, fileName, data, expectedRootID, expectedSHA256)
        await Spy.stage.pause()
        if let failure = await Spy.failure { throw failure }
        try await beforeCommit()
        // The real service independently checks cancellation before its exclusive rename.
        try Task.checkCancellation()
        await Spy.publish()
        await Spy.post.pause()
        return await Spy.result ?? MobileWorkspaceFileUpload(
            relativePath: relativeDirectoryPath.isEmpty ? fileName : relativeDirectoryPath + "/" + fileName,
            rootID: expectedRootID, byteCount: data.count, sha256: expectedSHA256)
    }
}
/*__LEAF__*/

@main @MainActor struct UploadHarness {
    static var assertions = 0, failures = 0
    static let id = UUID(uuidString: "2B6D9163-FE8B-44B1-8509-2A62D96688E9")!
    static let marker = String(repeating: "a", count: 64)
    static let direct = MobileHostConnectionAuthorizationContext.localDirect(.init(deviceID: "fixture"))
    static func check(_ value: Bool, _ label: String, line: UInt = #line) {
        assertions += 1
        if !value { failures += 1; print("FAIL \(label) line=\(line)") }
    }
    static func params(_ data: Data = Data([0, 255, 1]), path: String = "literal%2e%2e/~", name: String = "文件") -> [String: Any] {
        ["workspace_id": id.uuidString.lowercased(), "path": path, "root_id": marker, "file_name": name,
         "data_base64": data.base64EncodedString(), "byte_count": data.count,
         "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    private static func context(_ admission: Admission, auth: MobileHostConnectionAuthorizationContext = direct, validator: Bool = true) -> MobileHostRPCExecutionContext {
        if !validator { return .init(connectionID: UUID(), authorization: auth, artifactTransfers: nil) }
        return .init(connectionID: UUID(), authorization: auth, artifactTransfers: nil,
                     mutationAdmissionValidator: { await admission.validate() })
    }
    static func error(_ result: TerminalController.V2CallResult, _ expected: String) {
        guard case let .err(code, message, data) = result else { check(false, "expected \(expected)"); return }
        check(code == expected, "code=\(code), expected=\(expected)")
        check(data == nil && !message.contains("SECRET") && !message.contains("/fixture"), "safe nil error")
        if code == "file_transfer_disabled" { check(message == ManagedFileTransferPolicy.disabledMessage, "shared MDM refusal") }
    }
    static func balanced(_ quota: MobileTaskFilesystemJobQuota) {
        check(quota.acquire(), "our slot released")
        check(!quota.acquire(), "other job slot not released")
        quota.release(); quota.release()
    }
    static func immediate(_ expected: String, mode: String = "", request: [String: Any]? = nil) async {
        Spy.reset()
        let admission = Admission(), controller = TerminalController(id), quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire(), "other job owns slot")
        var ctx: MobileHostRPCExecutionContext? = context(admission)
        switch mode {
        case "nil": ctx = nil
        case "stack": ctx = context(admission, auth: .stackBearer)
        case "iroh": ctx = context(admission, auth: .irohAdmission(.init(bindingID: "fixture")))
        case "missing": ctx = context(admission, validator: false)
        case "revoked": await admission.revoke()
        case "mdm": ManagedFileTransferPolicy.state.withLock { $0 = true }
        case "remove": controller.workspace = nil
        case "remote": controller.workspace?.usesRemoteDirectoryProvenance = true
        case "relative": controller.workspace?.presentedCurrentDirectory = "relative"
        case "nullroot": controller.workspace?.presentedCurrentDirectory = nil
        case "nul": controller.workspace?.presentedCurrentDirectory = "/x\0y"
        case "long": controller.workspace?.presentedCurrentDirectory = "/" + String(repeating: "a", count: 4_096)
        case "busy": check(quota.acquire(), "saturate quota")
        default: break
        }
        let gate = Gate()
        let task = Task { @MainActor in
            await gate.pause()
            controller.last = await controller.v2MobileWorkspaceFileUpload(params: request ?? params(), executionContext: ctx, filesystemJobQuota: quota)
        }
        await gate.wait(); if mode == "cancel" { task.cancel() }; await gate.open(); await task.value
        if let result = controller.last { error(result, expected) } else { check(false, "missing response") }
        check(Spy.calls == 0 && Spy.published == 0, "no service or publication")
        if ["nil", "stack", "iroh", "missing", "revoked", "mdm", "cancel"].contains(mode) || expected == "invalid_params" {
            check(controller.lookups == 0, "no lookup before admission and parser")
        }
        if ["nil", "stack", "iroh", "missing", "mdm", "cancel"].contains(mode) {
            check(await admission.calls == 0, "validator not invoked")
        }
        if mode == "busy" { quota.release() }
        balanced(quota)
    }
    private static func mutate(_ mode: String, _ controller: TerminalController, _ admission: Admission) async {
        switch mode {
        case "mdm": ManagedFileTransferPolicy.state.withLock { $0 = true }
        case "revoke": await admission.revoke()
        case "remove": controller.workspace = nil
        case "replace": controller.workspace = Workspace(id)
        case "cwd": controller.workspace?.presentedCurrentDirectory = "/other"
        case "remote": controller.workspace?.usesRemoteDirectoryProvenance = true
        default: break
        }
    }
    static func run(mode: String = "", after: Bool = false, failure: (any Error)? = nil, expected: String? = nil,
                    data: Data = Data([0, 255, 1]), directory: String = "/fixture-authorized-root", path: String = "literal%2e%2e/~",
                    name: String = "文件", forged: MobileWorkspaceFileUpload? = nil) async {
        Spy.reset(); Spy.failure = failure; Spy.result = forged
        let admission = Admission(), controller = TerminalController(id), quota = MobileTaskFilesystemJobQuota()
        controller.workspace?.presentedCurrentDirectory = directory
        check(quota.acquire(), "other job owns slot")
        let request = params(data, path: path, name: name), ctx = context(admission)
        let task = Task { @MainActor in
            controller.last = await controller.v2MobileWorkspaceFileUpload(params: request, executionContext: ctx, filesystemJobQuota: quota)
        }
        await Spy.stage.wait()
        check(Spy.calls == 1 && Spy.published == 0, "staged but not published")
        check(!quota.acquire(), "quota held across await")
        check(Spy.directory.utf8.elementsEqual(path.utf8) && Spy.name.utf8.elementsEqual(name.utf8), "literal request")
        check(Spy.data == data && Spy.marker == marker && Spy.digest == request["sha256"] as? String, "exact bytes/root/digest")
        if !after { await mutate(mode, controller, admission); if mode == "cancel" { task.cancel() } }
        // Open post gate early on precommit refusals so a bad implementation cannot hang the negative control.
        let rejectsBefore = !after && (!mode.isEmpty || failure != nil)
        if rejectsBefore { await Spy.post.open() }
        await Spy.stage.open()
        if !rejectsBefore {
            await Spy.post.wait()
            check(Spy.published == 1, "published once before response")
            if after { await mutate(mode, controller, admission); if mode == "cancel" { task.cancel() } }
            await Spy.post.open()
        }
        await task.value
        check(Spy.published == (rejectsBefore ? 0 : 1), "publication boundary \(mode) after=\(after)")
        if let result = controller.last {
            if let expected { error(result, expected) }
            else if case let .ok(raw) = result, let fields = raw as? [String: Any] {
                check(Set(fields.keys) == ["workspace_id", "path", "root_id", "byte_count", "sha256", "absolute_path"], "exact six fields")
                let relative = path.isEmpty ? name : path + "/" + name
                var root = URL(fileURLWithPath: directory, isDirectory: true).path(percentEncoded: false)
                while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
                check(fields["absolute_path"] as? String == root + (root == "/" ? "" : "/") + relative, "authorized root-derived absolute path")
                check(fields["workspace_id"] as? String == id.uuidString, "canonical UUID")
                check((fields["path"] as? String)?.utf8.elementsEqual(relative.utf8) == true, "complete literal path")
                check(fields["root_id"] as? String == marker && fields["byte_count"] as? Int == data.count, "root and count")
                check(fields["sha256"] as? String == request["sha256"] as? String, "digest")
                check(await admission.calls == 3, "fresh entry, beforeCommit, postcommit gates")
            } else { check(false, "expected success") }
        } else { check(false, "missing response") }
        balanced(quota)
    }
    private static func admissionRace(_ cancel: Bool) async {
        Spy.reset()
        let gate = Gate(), controller = TerminalController(id), quota = MobileTaskFilesystemJobQuota()
        let admission = Admission(gate: gate), ctx = context(admission)
        check(quota.acquire(), "other job retained during admission")
        let task = Task { @MainActor in
            controller.last = await controller.v2MobileWorkspaceFileUpload(params: params(), executionContext: ctx, filesystemJobQuota: quota)
        }
        await gate.wait()
        if cancel { task.cancel() } else { ManagedFileTransferPolicy.state.withLock { $0 = true } }
        await gate.open(); await task.value
        if let result = controller.last { error(result, cancel ? "cancelled" : "file_transfer_disabled") }
        else { check(false, "missing admission race result") }
        check(Spy.calls == 0 && controller.lookups == 0, "post-validator MDM/cancel blocks service and lookup")
        check(await admission.calls == 1, "one suspended entry validator")
        balanced(quota)
    }
    static func main() async throws {
        await admissionRace(false); await admissionRace(true)
        for mode in ["nil", "stack", "iroh"] { await immediate("method_not_found", mode: mode) }
        for mode in ["missing", "revoked"] { await immediate("admission_expired", mode: mode) }
        await immediate("file_transfer_disabled", mode: "mdm")
        await immediate("cancelled", mode: "cancel")
        for (mode, code) in [("remove", "workspace_not_found"), ("remote", "unsupported_workspace"), ("busy", "busy"),
                             ("relative", "workspace_unavailable"), ("nullroot", "workspace_unavailable"),
                             ("nul", "workspace_unavailable"), ("long", "workspace_unavailable")] { await immediate(code, mode: mode) }
        for key in params().keys {
            var request = params(); request.removeValue(forKey: key); await immediate("invalid_params", request: request)
            for value: Any in [NSNull(), [], [:], true] {
                request = params(); request[key] = value; await immediate("invalid_params", request: request)
            }
        }
        for key in ["auth", "absolute_path", "overwrite", "offset", "command"] {
            var request = params(); request[key] = "SECRET"; await immediate("invalid_params", request: request)
        }
        var wrongID = params(); wrongID["workspace_id"] = UUID().uuidString
        await immediate("workspace_not_found", request: wrongID)
        for after in [false, true] {
            for (mode, code) in [("mdm", "file_transfer_disabled"), ("revoke", "admission_expired"), ("cancel", "cancelled"),
                                 ("remove", "workspace_changed"), ("replace", "workspace_changed"), ("cwd", "workspace_changed"), ("remote", "workspace_changed")] {
                await run(mode: mode, after: after, expected: code)
            }
        }
        let errors: [(MobileWorkspaceFileUploadError, String)] = [(.invalidRequest, "invalid_params"), (.invalidPath, "invalid_params"),
            (.rootChanged, "root_changed"), (.notFound, "directory_not_found"), (.notDirectory, "not_a_directory"),
            (.permissionDenied, "permission_denied"), (.alreadyExists, "file_already_exists"), (.tooLarge, "file_too_large"),
            (.integrityMismatch, "integrity_mismatch"), (.fileChanged, "file_changed"), (.unwritable, "unavailable")]
        for (failure, code) in errors { await run(failure: failure, expected: code) }
        await run(failure: CancellationError(), expected: "cancelled")
        await run(failure: NSError(domain: "SECRET /fixture", code: 1), expected: "unavailable")
        await run(mode: "mdm", failure: MobileWorkspaceFileUploadError.unwritable, expected: "file_transfer_disabled")
        for count in [0, 3, 256, 2_097_152] { await run(data: Data(repeating: 255, count: count)) }
        for directory in ["/", "/fixture///", "/fixture%20/中文/e\u{301}"] { await run(directory: directory, path: "", name: "%~e\u{301}") }
        let digest = params()["sha256"] as! String
        for forged in [MobileWorkspaceFileUpload(relativePath: "SECRET", rootID: marker, byteCount: 3, sha256: digest),
            .init(relativePath: "literal%2e%2e/~/文件", rootID: String(repeating: "b", count: 64), byteCount: 3, sha256: digest),
            .init(relativePath: "literal%2e%2e/~/文件", rootID: marker, byteCount: 4, sha256: digest),
            .init(relativePath: "literal%2e%2e/~/文件", rootID: marker, byteCount: 3, sha256: String(repeating: "b", count: 64))] {
            await run(expected: "unavailable", forged: forged)
        }
        let maxDirectory = ([String(repeating: "d", count: 240)] + Array(repeating: String(repeating: "d", count: 239), count: 15)).joined(separator: "/")
        let maxRoot = "/" + Array(repeating: String(repeating: "r", count: 255), count: 16).joined(separator: "/")
        await run(directory: maxRoot, path: maxDirectory, name: String(repeating: "n", count: 255))
        let maximum = params(Data(repeating: 255, count: 2_097_152), path: maxDirectory, name: String(repeating: "n", count: 255))
        let envelope: [String: Any] = ["id": "bounded-fixture-id", "method": "mobile.workspace.files.upload", "params": maximum]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        let frame = try MobileSyncFrameCodec.encodeFrame(json)
        check(frame.count < 8_388_608, "maximum escaped slash base64 request fits fixed frame")
        print("upload requestJSON=\(json.count) frame=\(frame.count)")
        print("Foundation home=\(FileManager.default.homeDirectoryForCurrentUser.path) temporaryDirectory=\(FileManager.default.temporaryDirectory.path)")
        print("upload assertions=\(assertions) failures=\(failures); controlled service, no real publication/authentication proof")
        exit(failures == 0 ? 0 : 1)
    }
}
