@testable import CmuxMobileSSH
import Foundation
import Testing

/// Lab-free decoding of cmux-tui browser wire shapes. Samples follow the
/// server serializers (`crates/cmux-tui-core/src/server.rs`:
/// `pane_json`, `BrowserStateMessage`, `browser_frame_json`) and
/// cmux-tui/spec/events.md.
@Suite struct CmuxTUIBrowserWireTests {
    static let listWorkspaces = #"""
    {"id":"r3","ok":true,"data":{"workspace_revision":4,"workspaces":[{"id":4,"key":"6ba7b810-9dad-41d1-80b4-00c04fd430c8","resource_id":"ws_1","name":"api","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"layout":{"type":"leaf","pane":2},"panes":[{"id":2,"name":null,"active_tab":1,"focused_at":1,"tabs":[{"surface":1,"tab_resource_id":"tab_a","content_resource_id":"term_a","terminal_id":"t-1","terminal_resource_id":"term_a","kind":"pty","browser_source":null,"browser_status":null,"browser_error":null,"browser_frames_stalled":null,"url":null,"name":null,"title":"zsh","size":{"cols":80,"rows":24},"dead":false},{"surface":7,"tab_resource_id":"tab_b","content_resource_id":"brw_0001","terminal_id":null,"terminal_resource_id":null,"kind":"browser","browser_source":"external","browser_status":"live","browser_error":null,"browser_frames_stalled":false,"url":"https://example.com/","name":null,"title":"Example Domain","size":{"cols":120,"rows":40},"dead":false}]}]}]}]}}
    """#

    @Test func listWorkspacesSeparatesBrowserTabs() throws {
        let response = try CmuxTUIRawResponse<CmuxTUITreeWire>(cmuxTUILine: Data(Self.listWorkspaces.utf8))
        let workspace = try #require(response.data?.model.first)
        #expect(workspace.terminals.map(\.surface) == [1])
        #expect(workspace.browsers.count == 1)
        let browser = try #require(workspace.browsers.first)
        #expect(browser.surface == 7)
        #expect(browser.pane == 2)
        #expect(browser.screen == 3)
        #expect(browser.resourceID == "brw_0001")
        #expect(browser.url == "https://example.com/")
        #expect(browser.title == "Example Domain")
        #expect(browser.status == .live)
        #expect(browser.cols == 120 && browser.rows == 40)
        #expect(!browser.dead && !browser.framesStalled)
    }

}
