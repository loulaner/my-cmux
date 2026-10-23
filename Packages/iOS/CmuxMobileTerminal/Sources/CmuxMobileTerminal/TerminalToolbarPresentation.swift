/// Immutable per-surface accessory presentation; never changes saved toolbar preferences.
public enum TerminalToolbarPresentation: Sendable, Equatable {
    /// Existing user-configurable toolbar, composer and customization controls.
    case standard
    /// Fixed terminal keys only, without launchers, custom actions or image paste.
    case terminalOnly

    #if canImport(UIKit)
    var fixedActions: [TerminalInputAccessoryAction]? {
        guard self == .terminalOnly else { return nil }
        return [.control, .alternate, .command, .shift, .tab, .escape, .returnKey,
                .upArrow, .downArrow, .leftArrow, .rightArrow, .ctrlC, .ctrlD, .ctrlZ, .ctrlL,
                .home, .end, .pageUp, .pageDown, .paste, .zoomOut, .zoomIn]
    }

    func allows(_ action: TerminalInputAccessoryAction) -> Bool {
        fixedActions?.contains(action) ?? true
    }
    #endif
}
