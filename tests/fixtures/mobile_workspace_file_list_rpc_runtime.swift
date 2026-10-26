// Control-flow fixture only. UI/context/async filesystem values are spies.
// Handler, parser, policy, capability, DTOs, shared refusal and quota are actual sources.
import Foundation
import CoreFoundation
import os

struct MobileHostRPCRequest { let id: String; let method: String; let params: [String: Any]; let auth: String? }
struct MobileHostRPCError { let code: String; let message: String }
enum MobileHostRPCResult { case failure(MobileHostRPCError); case success }
enum MobileHostService {
    // Explicit value fixtures, not claims about terminal wire constant coverage.
    static let terminalInputOrderedCapability = "fixture-ordered"
    static let terminalSharedSizingCapability = "fixture-sizing"
}
enum MobileTerminalInputDelivery { static let capability = "fixture-delivery" }
enum CmuxFeatureFlags {
    static let state = OSAllocatedUnfairLock(initialState: false)
    static let mobileWorkspaceChangesFlag = "fixture-changes"
    static func offMainEffectiveValue(for flag: String) -> Bool { state.withLock { $0 } }
}
enum ManagedFileTransferPolicy {
    static let state = OSAllocatedUnfairLock(initialState: false)
    static var isDisabled: Bool { state.withLock { $0 } }
    /*__OWNER__*/
}
/*__PARSER__*/
/*__POLICY__*/
/*__CAP__*/
/*__QUOTA__*/
/*__ENTRY__*/
/*__PAGE__*/
/*__ERROR__*/

enum MobileHostConnectionAuthorizationContext { case localDirect; case stackBearer; case irohAdmission }
@MainActor final class Workspace {
    let id: UUID
    var presentedCurrentDirectory: String? = "/fixture-authorized-root"
    var usesRemoteDirectoryProvenance = false
    init(_ id: UUID) { self.id = id }
}
@MainActor final class TerminalController {
    var workspace: Workspace?
    var last: V2CallResult?
    var lookups = 0
    init(_ id: UUID) { workspace = Workspace(id) }
    /*__RESULT__*/
    /*__HELPER__*/
    func v2ResolveTabManager(params: [String: Any]) -> TerminalController? {
        lookups += 1
        precondition(Set(params.keys) == ["workspace_id"])
        guard let id = params["workspace_id"] as? String, workspace?.id.uuidString == id else { return nil }
        return self
    }
    func v2ResolveWorkspace(params: [String: Any], tabManager: TerminalController) -> Workspace? {
        precondition(tabManager === self && Set(params.keys) == ["workspace_id"])
        return workspace
    }
}
// A continuation-controlled service spy; no filesystem calls or user paths.
@MainActor final class MobileWorkspaceFileListService {
    static var calls = 0
    static var roots: [String] = []
    static var requests: [(String, Int, Int)] = []
    static var started: (() -> Void)?
    static var continuation: CheckedContinuation<MobileWorkspaceFileListPage, any Error>?
    init(rootDirectory: URL) throws { Self.calls += 1; Self.roots.append(rootDirectory.path) }
    func list(relativePath: String, offset: Int, limit: Int) async throws -> MobileWorkspaceFileListPage {
        Self.requests.append((relativePath, offset, limit))
        return try await withCheckedThrowingContinuation { continuation in
            Self.continuation = continuation
            Self.started?()
        }
    }
}
/*__LEAF__*/
@MainActor enum Issue { static func record(_ message: String) { preconditionFailure(message) } }
/*__APP_POLICY_TESTS__*/

@main @MainActor struct Harness {
    static var assertions = 0
    static let identifier = UUID(uuidString: "2B6D9163-FE8B-44B1-8509-2A62D96688E9")!
    static let method = "mobile.workspace.files.list"
    static var params: [String: Any] { ["workspace_id": identifier.uuidString.lowercased()] }
    static func check(_ value: @autoclosure () -> Bool, _ label: String = "assertion", line: UInt = #line) {
        assertions += 1
        precondition(value(), "\(label) at \(line)")
    }
    static func reset() {
        ManagedFileTransferPolicy.state.withLock { $0 = false }
        MobileWorkspaceFileListService.calls = 0
        MobileWorkspaceFileListService.roots = []
        MobileWorkspaceFileListService.requests = []
        MobileWorkspaceFileListService.continuation = nil
        MobileWorkspaceFileListService.started = nil
    }
    static func error(_ result: TerminalController.V2CallResult, _ expected: String) {
        guard case let .err(code, message, data) = result else { preconditionFailure("Expected refusal") }
        check(code == expected, "error code \(expected)")
        check(data == nil && !message.contains("SECRET"), "safe error")
        if code == "file_transfer_disabled" { check(message == ManagedFileTransferPolicy.disabledMessage, "owner refusal") }
    }
    // One real quota slot is deliberately held by another job. Missing or extra
    // handler releases change the remaining capacity and fail these checks.
    static func balanced(_ quota: MobileTaskFilesystemJobQuota) {
        check(quota.acquire(), "handler released its slot")
        check(!quota.acquire(), "handler did not release the other job's slot")
        quota.release(); quota.release()
    }
    static func immediate(_ expected: String, authorization: MobileHostConnectionAuthorizationContext? = .localDirect,
                          request: [String: Any]? = nil, configure: (TerminalController) -> Void = { _ in }) async {
        reset()
        let controller = TerminalController(identifier)
        let quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire())
        configure(controller)
        let result = await controller.v2MobileWorkspaceFilesList(params: request ?? params,
            authorization: authorization, filesystemJobQuota: quota)
        error(result, expected)
        check(MobileWorkspaceFileListService.calls == 0, "preflight must not create service")
        balanced(quota)
    }
    static func page(nested: Bool) -> MobileWorkspaceFileListPage {
        let path = nested ? "literal%2e%2e/~" : ""
        let entries: [MobileWorkspaceFileListEntry] = [
            .init(name: "file", relativePath: "file", kind: .file, byteCount: 12),
            .init(name: "dir", relativePath: "dir", kind: .directory, byteCount: nil),
            .init(name: "link", relativePath: "link", kind: .symbolicLink, byteCount: nil),
            .init(name: "fifo", relativePath: "fifo", kind: .other, byteCount: nil),
        ]
        return MobileWorkspaceFileListPage(relativePath: path, parentRelativePath: nested ? "literal%2e%2e" : nil,
            entries: entries.map { .init(name: $0.name, relativePath: nested ? path + "/" + $0.name : $0.name,
                                        kind: $0.kind, byteCount: $0.byteCount) },
            offset: nested ? 3 : 0, limit: nested ? 4 : 100, totalCount: nested ? 10 : 4, nextOffset: nested ? 7 : nil, rootID: String(repeating: "0", count: 64))
    }
    static func suspended(_ scenario: String, failure: (any Error)? = nil, expected: String? = nil) async {
        reset()
        let controller = TerminalController(identifier)
        let quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire())
        let (events, signal) = AsyncStream<Void>.makeStream()
        MobileWorkspaceFileListService.started = { signal.yield(()) }
        let nested = scenario == "nested"
        let expectedPath = nested ? "literal%2e%2e/~" : ""
        let expectedOffset = nested ? 3 : 0
        let expectedLimit = nested ? 4 : 100
        let task = Task { @MainActor in
            var request = params
            if nested { request["path"] = expectedPath; request["offset"] = expectedOffset; request["limit"] = expectedLimit }
            controller.last = await controller.v2MobileWorkspaceFilesList(params: request,
                authorization: .localDirect, filesystemJobQuota: quota)
        }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        check(MobileWorkspaceFileListService.calls == 1)
        check(MobileWorkspaceFileListService.roots == ["/fixture-authorized-root"])
        check(MobileWorkspaceFileListService.requests.first?.0 == expectedPath)
        check(MobileWorkspaceFileListService.requests.first?.1 == expectedOffset)
        check(MobileWorkspaceFileListService.requests.first?.2 == expectedLimit)
        check(!quota.acquire(), "both real slots held during await")
        switch scenario {
        case "mdm", "mdm-error", "mdm-cancel": ManagedFileTransferPolicy.state.withLock { $0 = true }
        case "directory": controller.workspace?.presentedCurrentDirectory = "/fixture-changed"
        case "remote": controller.workspace?.usesRemoteDirectoryProvenance = true
        case "removed": controller.workspace = nil
        case "replaced": controller.workspace = Workspace(identifier)
        default: break
        }
        if scenario == "cancel" || scenario == "mdm-cancel" { task.cancel() }
        let continuation = MobileWorkspaceFileListService.continuation!
        MobileWorkspaceFileListService.continuation = nil
        if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: page(nested: nested)) }
        signal.finish()
        await task.value
        let result = controller.last!
        if let expected { error(result, expected) }
        else {
            guard case .ok(let raw) = result, let payload = raw as? [String: Any] else { preconditionFailure("Expected page") }
            check(Set(payload.keys) == ["workspace_id", "path", "parent_path", "entries", "offset", "limit", "total_count", "next_offset"])
            check(payload["workspace_id"] as? String == identifier.uuidString)
            check(payload["path"] as? String == expectedPath)
            check(payload["offset"] as? Int == expectedOffset && payload["limit"] as? Int == expectedLimit)
            check(payload["total_count"] as? Int == (nested ? 10 : 4))
            if nested {
                check(payload["parent_path"] as? String == "literal%2e%2e" && payload["next_offset"] as? Int == 7)
            } else { check(payload["parent_path"] is NSNull && payload["next_offset"] is NSNull) }
            guard let entries = payload["entries"] as? [[String: Any]] else { preconditionFailure("Invalid entry shape") }
            check(entries.compactMap { $0["kind"] as? String } == ["file", "directory", "symbolicLink", "other"])
            check(entries[0]["size"] as? Int64 == 12)
            check(entries.compactMap { $0["path"] as? String } == page(nested: nested).entries.map(\.relativePath))
            for entry in entries { check(Set(entry.keys) == ["name", "path", "kind", "size"]) }
            for entry in entries.dropFirst() { check(entry["size"] is NSNull) }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let encoded = String(data: data, encoding: .utf8) else { preconditionFailure("Invalid JSON payload") }
            check(!encoded.contains("fixture-authorized-root"), "root is not returned")
        }
        balanced(quota)
    }
    static func policyCode(_ policy: MobileLocalDirectRPCPolicy, _ method: String, _ request: [String: Any]) -> String? {
        guard let result = policy.authorizationError(for: .init(id: "fixture", method: method, params: request, auth: nil)) else { return nil }
        guard case .failure(let error) = result else { preconditionFailure("Unexpected policy value") }
        return error.code
    }
    static func policy() {
        let base = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: false, fileTransferDisabled: true)
        for enabled in [false, true] {
            CmuxFeatureFlags.state.withLock { $0 = enabled }
            for disabled in [false, true] {
                ManagedFileTransferPolicy.state.withLock { $0 = disabled }
                let current = MobileLocalDirectRPCPolicy()
                let admittedChanges = enabled && !disabled
                check(current.methods == base.methods.union(admittedChanges ? ["mobile.workspace.changes.files", "mobile.workspace.changes.file_diff"] : [])
                    .union(disabled ? [] : [method]))
                check(current.capabilities == base.capabilities + (admittedChanges ? [CmxLocalDirectCapabilities.workspaceChangesRead] : [])
                    + (disabled ? [] : [CmxLocalDirectCapabilities.workspaceFilesList]))
                check(current.topics == base.topics)
                check(policyCode(current, method, params) == (disabled ? "file_transfer_disabled" : nil))
                check(policyCode(current, method, [:]) == (disabled ? "file_transfer_disabled" : "invalid_params"))
                for terminal in base.methods where terminal != "mobile.events.subscribe" { check(policyCode(current, terminal, [:]) == nil) }
                for forbidden in ["mobile.directory.list", "mobile.directory.search", "mobile.workspace.files.fetch",
                                  "mobile.workspace.changes.file_fetch", "mobile.upload.begin", "mobile.workspace.files.write"] {
                    check(policyCode(current, forbidden, params) == "method_not_found")
                }
                ManagedFileTransferPolicy.state.withLock { $0 = !disabled }
                check(current.methods.contains(method) == !disabled, "old immutable snapshot")
                check(MobileLocalDirectRPCPolicy().methods.contains(method) == disabled, "fresh snapshot")
            }
        }
    }
    static func main() async throws {
        let filesPolicy = MobileLocalDirectWorkspaceFilesPolicyTests()
        filesPolicy.independentFilesGateAndDeniedLegacySurface()
        filesPolicy.parserBoundaryAndUnchangedSnapshots()
        let changesPolicy = MobileLocalDirectChangesPolicyTests()
        changesPolicy.gatesAndCapabilitiesAgree()
        changesPolicy.strictWorkspaceAndKeys()
        changesPolicy.strictRelativePath()
        try changesPolicy.boundedNonBooleanIntegerBudget()
        policy()
        await immediate("method_not_found", authorization: nil)
        await immediate("method_not_found", authorization: .stackBearer)
        await immediate("method_not_found", authorization: .irohAdmission)
        await immediate("method_not_found", authorization: nil) { _ in ManagedFileTransferPolicy.state.withLock { $0 = true } }
        await immediate("method_not_found", authorization: .stackBearer,
                        request: ["workspace_id": identifier.uuidString, "auth": "localDirect", "transport": "localDirect"])
        await immediate("file_transfer_disabled", request: [:]) { _ in ManagedFileTransferPolicy.state.withLock { $0 = true } }
        for invalid: [String: Any] in [[:], ["workspace_id": identifier.uuidString, "auth": "direct"],
            ["workspace_id": identifier.uuidString, "path": "../outside"], ["workspace_id": identifier.uuidString, "offset": true]] {
            await immediate("invalid_params", request: invalid)
        }
        await immediate("workspace_not_found") { $0.workspace = nil }
        await immediate("workspace_not_found", request: ["workspace_id": UUID().uuidString])
        await immediate("unsupported_workspace") { $0.workspace?.usesRemoteDirectoryProvenance = true }
        for directory in [nil, "", "relative", "~", "/bad\0root", "/" + String(repeating: "x", count: 4096)] {
            await immediate("workspace_unavailable") { $0.workspace?.presentedCurrentDirectory = directory }
        }
        reset()
        let quota = MobileTaskFilesystemJobQuota()
        check(quota.acquire() && quota.acquire())
        error(await TerminalController(identifier).v2MobileWorkspaceFilesList(params: params, authorization: .localDirect,
            filesystemJobQuota: quota), "busy")
        check(MobileWorkspaceFileListService.calls == 0 && !quota.acquire())
        quota.release(); quota.release()
        await suspended("success")
        await suspended("nested")
        await suspended("mdm", expected: "file_transfer_disabled")
        await suspended("cancel", expected: "cancelled")
        await suspended("mdm-cancel", expected: "file_transfer_disabled")
        for scenario in ["directory", "remote", "removed", "replaced"] { await suspended(scenario, expected: "workspace_changed") }
        for (failure, code): (MobileWorkspaceFileListError, String) in [(.invalidRequest, "invalid_params"), (.invalidPath, "invalid_params"),
            (.notFound, "directory_not_found"), (.notDirectory, "not_a_directory"), (.permissionDenied, "permission_denied"),
            (.tooManyEntries, "limit_exceeded"), (.unreadable, "unavailable")] {
            await suspended("error", failure: failure, expected: code)
        }
        await suspended("error", failure: CancellationError(), expected: "cancelled")
        let secret = NSError(domain: "SECRET-root-errno", code: 999, userInfo: [NSLocalizedDescriptionKey: "SECRET-path"])
        await suspended("error", failure: secret, expected: "unavailable")
        await suspended("mdm-error", failure: secret, expected: "file_transfer_disabled")
        print("PASS handler/policy/parser/quota \(assertions) assertions; controlled spies, not live authentication or filesystem")
    }
}
