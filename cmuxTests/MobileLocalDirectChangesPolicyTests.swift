import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileLocalDirectChangesPolicyTests {
    private let workspace = "2B6D9163-FE8B-44B1-8509-2A62D96688E9"
    private let files = "mobile.workspace.changes.files"
    private let diff = "mobile.workspace.changes.file_diff"

    private func error(_ policy: MobileLocalDirectRPCPolicy, _ method: String, _ params: [String: Any]) -> String? {
        guard let result = policy.authorizationError(for: MobileHostRPCRequest(
            id: "policy-test", method: method, params: params, auth: nil
        )) else { return nil }
        guard case .failure(let error) = result else { Issue.record("Unexpected result"); return "unexpected" }
        return error.code
    }

    @Test func gatesAndCapabilitiesAgree() {
        let base = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: false, fileTransferDisabled: true)
        for enabled in [false, true] {
            for disabled in [false, true] {
                let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: enabled, fileTransferDisabled: disabled)
                let admitted = enabled && !disabled
                #expect(policy.methods == (admitted ? base.methods.union([files, diff]) : base.methods).union(disabled ? [] : ["mobile.workspace.files.list"]))
                #expect(policy.capabilities == base.capabilities + (admitted ? [CmxLocalDirectCapabilities.workspaceChangesRead] : [])
                    + (disabled ? [] : [CmxLocalDirectCapabilities.workspaceFilesList]))
                #expect(!policy.capabilities.contains("workspace.changes.v1"))
                #expect(policy.topics == base.topics)
                for method in [files, diff] {
                    let params: [String: Any] = method == files ? ["workspace_id": workspace] : ["workspace_id": workspace, "path": "src/a.swift"]
                    let expected = disabled ? "file_transfer_disabled" : (enabled ? nil : "capability_disabled")
                    #expect(error(policy, method, params) == expected)
                    if !admitted { #expect(error(policy, method, [:]) == expected) }
                }
                for method in base.methods where method != "mobile.events.subscribe" {
                    #expect(error(policy, method, [:]) == nil)
                }
                #expect(error(policy, "mobile.events.subscribe", ["topics": Array(base.topics)]) == nil)
                for topics in [["*"], ["terminal.bytes", "feed.changed"], []] {
                    #expect(error(policy, "mobile.events.subscribe", ["topics": topics]) == "invalid_params")
                }
                for method in ["mobile.workspace.changes.summary", "mobile.workspace.changes.file_stat",
                               "mobile.workspace.changes.file_fetch", "mobile.workspace.changes.write",
                               "mobile.upload.begin", "workspace.create", "terminal.spawn", "mobile.artifact.fetch"] {
                    #expect(error(policy, method, ["workspace_id": workspace]) == "method_not_found")
                }
            }
        }
    }

    @Test func strictWorkspaceAndKeys() {
        let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: true, fileTransferDisabled: false)
        for method in [files, diff] {
            let valid: [String: Any] = method == files ? ["workspace_id": workspace] : ["workspace_id": workspace, "path": "a"]
            #expect(error(policy, method, valid) == nil)
            var missing = valid
            missing.removeValue(forKey: "workspace_id")
            #expect(error(policy, method, missing) == "invalid_params")
            for id: Any in [NSNull(), "", "workspace:1", "not-a-uuid", 1, true] {
                var params = valid
                params["workspace_id"] = id
                #expect(error(policy, method, params) == "invalid_params")
            }
            for key in ["command", "initial_command", "tmux_start_command", "pane_start_command", "workspace",
                        "workspace_ref", "surface_id", "directory", "absolute_path", "transport", "auth", "unknown"] {
                var params = valid
                params[key] = NSNull()
                #expect(error(policy, method, params) == "invalid_params")
            }
        }
        for key in ["path", "max_lines"] {
            #expect(error(policy, files, ["workspace_id": workspace, key: "extra"]) == "invalid_params")
        }
    }

    @Test func strictRelativePath() {
        let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: true, fileTransferDisabled: false)
        #expect(error(policy, diff, ["workspace_id": workspace]) == "invalid_params")
        for path: Any in [NSNull(), 7, true, "", "/tmp/a", "a/", "a//b", ".", "..", "./a", "a/./b", "a/../b", "a\0b"] {
            #expect(error(policy, diff, ["workspace_id": workspace, "path": path]) == "invalid_params")
        }
        // Literal names remain literal; no expansion, shell interpretation or filesystem lookup.
        for path in ["a", "src/中文 [a].swift", "space name", "~/literal", "$(echo literal)", "a\\b"] {
            #expect(error(policy, diff, ["workspace_id": workspace, "path": path]) == nil)
        }
    }

    @Test func boundedNonBooleanIntegerBudget() throws {
        let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: true, fileTransferDisabled: false)
        let valid: [String: Any] = ["workspace_id": workspace, "path": "a"]
        #expect(error(policy, diff, valid) == nil)
        for value: Any in [1, 6_000, NSNumber(value: 2)] {
            var params = valid
            params["max_lines"] = value
            #expect(error(policy, diff, params) == nil)
        }
        for value: Any in [true, false, NSNumber(value: true), NSNull(), 0, -1, 6_001, Int.max, 1.5, "1", [], ["value": 1]] {
            var params = valid
            params["max_lines"] = value
            #expect(error(policy, diff, params) == "invalid_params")
        }
        for (json, expected) in [("true", "invalid_params"), ("false", "invalid_params"), ("1", nil),
                                 ("6000", nil), ("6001", "invalid_params"), ("1.5", "invalid_params"), ("null", "invalid_params")] {
            guard let params = try JSONSerialization.jsonObject(with: Data("{\"workspace_id\":\"\(workspace)\",\"path\":\"a\",\"max_lines\":\(json)}".utf8)) as? [String: Any] else {
                Issue.record("Invalid JSON fixture"); return
            }
            #expect(error(policy, diff, params) == expected)
        }
    }
}
