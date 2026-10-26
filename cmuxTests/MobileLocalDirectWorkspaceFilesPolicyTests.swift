import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileLocalDirectWorkspaceFilesPolicyTests {
    private let identifier = "2B6D9163-FE8B-44B1-8509-2A62D96688E9"
    private let method = "mobile.workspace.files.list"

    private func code(_ policy: MobileLocalDirectRPCPolicy, method: String, params: [String: Any]) -> String? {
        guard let result = policy.authorizationError(for: MobileHostRPCRequest(id: "files-policy", method: method, params: params, auth: nil)) else { return nil }
        guard case .failure(let error) = result else { Issue.record("Unexpected result"); return "unexpected" }
        return error.code
    }

    @Test func independentFilesGateAndDeniedLegacySurface() {
        let base = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: false, fileTransferDisabled: true)
        for changes in [false, true] {
            for disabled in [false, true] {
                let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: changes, fileTransferDisabled: disabled)
                #expect(policy.methods.contains(method) == !disabled)
                #expect(policy.capabilities.contains(CmxLocalDirectCapabilities.workspaceFilesList) == !disabled)
                #expect(code(policy, method: method, params: ["workspace_id": identifier]) == (disabled ? "file_transfer_disabled" : nil))
                #expect(code(policy, method: method, params: [:]) == (disabled ? "file_transfer_disabled" : "invalid_params"))
                #expect(policy.topics == base.topics)
                for terminal in base.methods where terminal != "mobile.events.subscribe" {
                    #expect(code(policy, method: terminal, params: [:]) == nil)
                }
                for denied in ["mobile.directory.list", "mobile.directory.search", "mobile.workspace.files.fetch",
                               "mobile.workspace.changes.file_fetch", "mobile.upload.begin", "mobile.workspace.files.write"] {
                    #expect(code(policy, method: denied, params: ["workspace_id": identifier]) == "method_not_found")
                }
            }
        }
    }

    @Test func parserBoundaryAndUnchangedSnapshots() {
        let allowed = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: false, fileTransferDisabled: false)
        let denied = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: true, fileTransferDisabled: true)
        for params: [String: Any] in [["workspace_id": identifier, "auth": "direct"],
            ["workspace_id": identifier, "path": "/absolute"], ["workspace_id": identifier, "offset": true],
            ["workspace_id": identifier, "limit": 101], ["workspace_id": NSNull()]] {
            #expect(code(allowed, method: method, params: params) == "invalid_params")
            #expect(code(denied, method: method, params: params) == "file_transfer_disabled")
        }
        #expect(allowed.methods.contains(method) && !denied.methods.contains(method))
        #expect(code(allowed, method: method, params: ["workspace_id": identifier, "path": "%2e%2e/~", "offset": Int.max]) == nil)
    }
}
