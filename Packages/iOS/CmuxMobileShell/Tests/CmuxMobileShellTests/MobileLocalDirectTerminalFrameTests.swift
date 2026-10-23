import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

struct MobileLocalDirectTerminalFrameTests {
    @Test func historyAndAnchorMustMatchDeliveredScreen() throws {
        let base = try MobileTerminalRenderGridFrame(surfaceID: "fixture", stateSeq: 1, renderEpoch: "epoch", renderRevision: 1,
            columns: 20, rows: 5, full: true, styles: [], rowSpans: [], anchor: .screen, historyRows: 4)
        var next = base
        next.full = false; next.renderRevision = 2; next.deltaBaseRenderRevision = 1
        next.deltaBaseHistoryRows = 3; next.activeScreen = .primary
        #expect(MobileLocalDirectTerminalFrame.classify(next, delivered: base) == .chainBreak)
        next = base; next.anchor = .viewport; next.renderRevision = 2
        #expect(MobileLocalDirectTerminalFrame.classify(next, delivered: base) == .chainBreak)
    }
}
