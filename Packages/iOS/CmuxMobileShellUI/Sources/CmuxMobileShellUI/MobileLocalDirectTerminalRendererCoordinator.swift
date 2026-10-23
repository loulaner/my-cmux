#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import Foundation

/// Applies exactly one selected session's output on Ghostty's existing ordered queue.
@MainActor
public final class MobileLocalDirectTerminalRendererCoordinator: GhosttySurfaceViewDelegate {
    let session: MobileLocalDirectTerminalSession
    weak var surface: GhosttySurfaceView?
    #if DEBUG
    private var traceCount = 0
    private var tracedRecovery = false
    private func trace(_ stage: String) {
        guard traceCount < 64, !tracedRecovery else { return }
        traceCount += 1
        NSLog("[direct-terminal-renderer] %@", stage)
    }
    #endif
    init(session: MobileLocalDirectTerminalSession) { self.session = session }

    public func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didChangeWindowAttachment attached: Bool) {
        #if DEBUG
        if attached { traceCount = 0; tracedRecovery = false }
        trace("attachment attached=\(attached)")
        #endif
        if !attached { session.unmount(); return }
        session.mount(apply: { [weak self, weak surfaceView] frame, bytes in
            guard let surfaceView, !Task.isCancelled else { return false }
            if frame.full {
                #if DEBUG
                self?.trace("geometry.begin cols=\(frame.columns) rows=\(frame.rows)")
                #endif
                let sized = await surfaceView.applyViewSizeAndWait(cols: frame.columns, rows: frame.rows)
                #if DEBUG
                self?.trace("geometry.complete success=\(sized)")
                #endif
                guard sized, !Task.isCancelled else { return false }
            }
            if let theme = frame.terminalTheme { surfaceView.terminalTheme = theme }
            if let config = frame.terminalConfigTheme { surfaceView.terminalConfigTheme = config }
            surfaceView.hostedAltScreenActive = frame.activeScreen == .alternate
            #if DEBUG
            self?.trace("output.begin")
            #endif
            let applied = await surfaceView.processOutputAndWait(bytes, terminalConfigTheme: frame.terminalConfigTheme,
                renderGridContract: .init(columns: frame.columns, rows: frame.rows, isDelta: !frame.full),
                pushesLocalScrollbackRows: frame.scrolledRows)
            #if DEBUG
            self?.trace("output.complete success=\(applied)")
            if applied { self?.tracedRecovery = true }
            #endif
            return applied
        }, confirmViewport: { [weak surfaceView] columns, rows, reportID in
            surfaceView?.applyConfirmedViewSize(cols: columns, rows: rows, reportID: reportID)
        })
        surfaceView.requestForegroundViewportRefresh()
    }
    public func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) { session.input(data) }
    public func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        session.resize(columns: size.columns, rows: size.rows, reportID: reportID)
    }
    public func ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(_ surfaceView: GhosttySurfaceView) -> Bool { session.ownsLocalPrimaryScroll }
    public func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int) {
        session.scroll(lines: lines, col: col, row: row)
    }
    public func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) async -> GhosttySurfaceTapDisposition {
        session.tap(col: col, row: row)
        return .focusTerminal
    }
    public func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {
        session.rendererRebuilt()
    }
    public func ghosttySurfaceViewDidExhaustOutputConsumerRecovery(_ surfaceView: GhosttySurfaceView) { session.rendererUnavailable() }
}
#endif
