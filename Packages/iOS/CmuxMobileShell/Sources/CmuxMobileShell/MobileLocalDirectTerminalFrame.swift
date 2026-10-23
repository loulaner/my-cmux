import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Screen-only validation and replay synthesis, run off the UI actor.
struct MobileLocalDirectTerminalFrame: Sendable {
    let frame: MobileTerminalRenderGridFrame
    let bytes: Data

    static func classify(_ frame: MobileTerminalRenderGridFrame, delivered: MobileTerminalRenderGridFrame?) -> MobileTerminalRenderGridRevisionContinuity.Verdict {
        guard frame.anchor == .screen else { return .chainBreak }
        let verdict = MobileTerminalRenderGridRevisionContinuity.classify(frame,
            delivered: delivered.map(MobileTerminalRenderGridRevisionContinuity.init(delivered:)))
        guard verdict == .admit else { return verdict }
        if !frame.full {
            guard delivered != nil, frame.deltaBaseRenderRevision != nil else { return .chainBreak }
            if frame.activeScreen == .primary,
               frame.deltaBaseHistoryRows == nil || frame.deltaBaseHistoryRows != delivered?.historyRows { return .chainBreak }
        }
        return .admit
    }
    static func decode(_ data: Data, workspaceID: String, surfaceID: String, replay: Bool) throws -> Self? {
        try Task.checkCancellation()
        guard data.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MobileShellConnectionError.invalidResponse }
        if let workspace = object["workspace_id"] as? String,
           workspace.caseInsensitiveCompare(workspaceID) != .orderedSame { return nil }
        if let target = object["surface_id"] as? String,
           target.caseInsensitiveCompare(surfaceID) != .orderedSame { return nil }
        let grid = object["render_grid"] as? [String: Any] ?? (replay ? [:] : object)
        if let target = grid["surface_id"] as? String,
           target.caseInsensitiveCompare(surfaceID) != .orderedSame { return nil }
        guard let columns = grid["columns"] as? Int, let rows = grid["rows"] as? Int,
              (1...1000).contains(columns), (1...1000).contains(rows),
              (0...MobileTerminalScrollbackPreference.maximumRows).contains(grid["scrollback_rows"] as? Int ?? 0) else {
            throw MobileShellConnectionError.invalidResponse
        }
        let frame: MobileTerminalRenderGridFrame
        if replay {
            let response = try MobileTerminalReplayResponse.decode(data)
            guard !response.namesAnotherTerminal(than: surfaceID), let value = response.renderGrid, value.full else {
                throw MobileShellConnectionError.invalidResponse
            }
            frame = value
        } else {
            frame = try MobileTerminalRenderGridEvent.decode(data).frame ?? MobileTerminalRenderGridFrame.decode(data)
        }
        guard frame.surfaceID.caseInsensitiveCompare(surfaceID) == .orderedSame else { return nil }
        try Task.checkCancellation()
        return Self(frame: frame, bytes: frame.vtPatchBytes())
    }
}

