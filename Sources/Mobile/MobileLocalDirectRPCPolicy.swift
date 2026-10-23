import CMUXMobileCore
import Foundation

/// The deliberately small existing-terminal RPC surface for local direct sessions.
struct MobileLocalDirectRPCPolicy: Sendable {
    let methods: Set<String> = [
        "mobile.host.status", "mobile.events.subscribe", "mobile.events.unsubscribe", "mobile.events.probe",
        "workspace.list", "mobile.workspace.list", "mobile.terminal.input", "terminal.input",
        "mobile.terminal.paste", "terminal.paste", "mobile.terminal.replay", "terminal.replay",
        "mobile.terminal.viewport", "terminal.viewport", "mobile.terminal.scroll", "terminal.scroll",
        "mobile.terminal.mouse", "terminal.mouse", "mobile.terminal.reattach",
        "mobile.terminal.size_policy.set", "mobile.terminal.participant.disconnect"
    ]
    let topics: Set<String> = [
        "workspace.updated", "mobile.sync.delta", "terminal.render_grid", "terminal.bytes",
        "mobile.terminal.size_state", "mobile.terminal.detached"
    ]
    var capabilities: [String] {
        ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1",
         "terminal.render_grid.verified_replay.v1", "terminal.render_grid.screen_anchor.v1",
         "terminal.replay.v1", "terminal.viewport.v1", MobileHostService.terminalInputOrderedCapability,
         MobileTerminalInputDelivery.capability, MobileHostService.terminalSharedSizingCapability]
    }

    /// Runs before subscription handling as well as before terminal dispatch.
    func authorizationError(for request: MobileHostRPCRequest) -> MobileHostRPCResult? {
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
}
