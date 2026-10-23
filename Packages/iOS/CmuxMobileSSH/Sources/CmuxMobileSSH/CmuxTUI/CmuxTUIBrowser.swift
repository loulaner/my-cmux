import Foundation

// Browser surfaces over the cmux-tui control protocol (protocol v12 with
// `browser-pointer-frame-guard-v1`; cmux-tui/docs/protocol.md "Attach
// Surface", spec/events.md `browser-state`/`frame`). A browser tab exists
// only when the server runs a `cmux-browser` provider; cmux-tui never
// launches Chrome itself.

/// Lifecycle of a browser surface's CDP runtime.
public enum CmuxTUIBrowserStatus: String, Sendable, Equatable {
    case starting
    case live
    case failed
}

/// One browser tab placed in a workspace (`list-workspaces`, `kind:"browser"`).
public struct CmuxTUIBrowserTab: Sendable, Equatable, Identifiable {
    public var id: Int { surface }
    /// Numeric surface id used by attach and browser commands; valid for this
    /// daemon generation only.
    public var surface: Int
    public var pane: Int
    public var screen: Int
    /// Stable browser content id (`content_resource_id`). Prefer it for storage.
    public var resourceID: String?
    public var url: String?
    public var title: String
    public var status: CmuxTUIBrowserStatus?
    public var error: String?
    public var framesStalled: Bool
    public var cols: Int?
    public var rows: Int?
    public var dead: Bool
}

struct CmuxTUICellPixelsWire: Decodable {
    var width_px: Int
    var height_px: Int
}
