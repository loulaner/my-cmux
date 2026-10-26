import CmuxCloud
import CmuxMobileHost
import CoreFoundation
import CMUXMobileCore
import Foundation

/// The deliberately small existing-terminal RPC surface for local direct sessions.
struct MobileLocalDirectRPCPolicy: Sendable {
    private let baseMethods: Set<String> = [
        "mobile.host.status", "mobile.events.subscribe", "mobile.events.unsubscribe", "mobile.events.probe",
        "workspace.list", "mobile.workspace.list", "mobile.terminal.input", "terminal.input",
        "mobile.terminal.paste", "terminal.paste", "mobile.terminal.replay", "terminal.replay",
        "mobile.terminal.viewport", "terminal.viewport", "mobile.terminal.scroll", "terminal.scroll",
        "mobile.terminal.mouse", "terminal.mouse", "mobile.terminal.reattach",
        "mobile.terminal.size_policy.set", "mobile.terminal.participant.disconnect"
    ]
    private let workspaceChangesEnabled: Bool
    private let fileTransferDisabled: Bool
    private let changesMethods: Set<String> = [
        "mobile.workspace.changes.files", "mobile.workspace.changes.file_diff"
    ]

    init(
        workspaceChangesEnabled: Bool = CmuxFeatureFlags.offMainEffectiveValue(for: CmuxFeatureFlags.mobileWorkspaceChangesFlag),
        fileTransferDisabled: Bool = ManagedFileTransferPolicy.isDisabled
    ) {
        self.workspaceChangesEnabled = workspaceChangesEnabled
        self.fileTransferDisabled = fileTransferDisabled
    }

    var methods: Set<String> {
        var allowed = workspaceChangesEnabled && !fileTransferDisabled ? baseMethods.union(changesMethods) : baseMethods
        if !fileTransferDisabled { allowed.formUnion(["mobile.workspace.files.list", "mobile.workspace.files.preview"]) }
        return allowed
    }

    let topics: Set<String> = [
        "workspace.updated", "mobile.sync.delta", "terminal.render_grid", "terminal.bytes",
        "mobile.terminal.size_state", "mobile.terminal.detached"
    ]
    var capabilities: [String] {
        let base = ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1",
         "terminal.render_grid.verified_replay.v1", "terminal.render_grid.screen_anchor.v1",
         "terminal.replay.v1", "terminal.viewport.v1", MobileHostService.terminalInputOrderedCapability,
         MobileTerminalInputDelivery.capability, MobileHostService.terminalSharedSizingCapability]
        let changes = workspaceChangesEnabled && !fileTransferDisabled
            ? [CmxLocalDirectCapabilities.workspaceChangesRead] : []
        return base + changes + (fileTransferDisabled ? [] : [CmxLocalDirectCapabilities.workspaceFilesList, CmxLocalDirectCapabilities.workspaceFilesPreview])
    }

    /// Runs before subscription handling as well as before terminal dispatch.
    func authorizationError(for request: MobileHostRPCRequest) -> MobileHostRPCResult? {
        if request.method == "mobile.workspace.files.list" || request.method == "mobile.workspace.files.preview" {
            if fileTransferDisabled {
                return .failure(MobileHostRPCError(
                    code: "file_transfer_disabled", message: ManagedFileTransferPolicy.disabledMessage
                ))
            }
            let valid = request.method == "mobile.workspace.files.list"
                ? MobileWorkspaceFileListRequest(params: request.params) != nil
                : MobileWorkspaceFilePreviewRequest(params: request.params) != nil
            guard valid else {
                return .failure(MobileHostRPCError(code: "invalid_params", message: String(
                    localized: "mobile.localDirect.files.error.invalidParams", defaultValue: "Invalid workspace file request"
                )))
            }
            return nil
        }
        if changesMethods.contains(request.method) {
            if fileTransferDisabled {
                return .failure(MobileHostRPCError(
                    code: "file_transfer_disabled", message: ManagedFileTransferPolicy.disabledMessage
                ))
            }
            guard workspaceChangesEnabled else {
                return .failure(MobileHostRPCError(code: "capability_disabled", message: String(
                    localized: "mobile.workspaceChanges.error.capabilityDisabled",
                    defaultValue: "Workspace changes are not enabled on this Mac"
                )))
            }
            guard validChangesParameters(request) else {
                return .failure(MobileHostRPCError(code: "invalid_params", message: String(
                    localized: "mobile.localDirect.workspaceChanges.error.invalidParams",
                    defaultValue: "Invalid workspace changes request"
                )))
            }
            return nil
        }
        guard methods.contains(request.method) else {
            return .failure(MobileHostRPCError(code: "method_not_found", message: "Unknown method"))
        }
        if request.method == "mobile.events.subscribe" {
            guard let requested = request.params["topics"] as? [String], !requested.isEmpty,
                  Set(requested).isSubset(of: topics) else {
                return .failure(MobileHostRPCError(code: "invalid_params", message: "Invalid topics"))
            }
        }
        return nil
    }

    private func validChangesParameters(_ request: MobileHostRPCRequest) -> Bool {
        let isDiff = request.method == "mobile.workspace.changes.file_diff"
        let allowed: Set<String> = isDiff ? ["workspace_id", "path", "max_lines"] : ["workspace_id"]
        guard Set(request.params.keys).isSubset(of: allowed),
              let workspaceID = request.params["workspace_id"] as? String,
              UUID(uuidString: workspaceID) != nil else { return false }
        guard isDiff else { return true }
        guard let path = request.params["path"] as? String, !path.isEmpty,
              !path.contains("\0"), !path.hasPrefix("/"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else { return false }
        if let value = request.params["max_lines"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let limit = value as? Int, (1...6_000).contains(limit) else { return false }
        }
        return true
    }
}
