import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistoryLocationTests {
    @Test func myCMUXTagsDoNotShareHistoryOrImportLegacyHistory() {
        let root = URL(fileURLWithPath: "/synthetic/appsupport")
        let first = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.loulaner.mycmux.debug.one")
        let second = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.loulaner.mycmux.debug.two")
        #expect(first.historyFileURL != second.historyFileURL)
        #expect(first.historyFileURL.path == "/synthetic/appsupport/MyCMUX/com.loulaner.mycmux.debug.one/browser_history.json")
        #expect(first.legacyTaggedHistoryFileURL == nil)
        #expect(second.legacyTaggedHistoryFileURL == nil)
    }

    @Test func foldsDebugAndStagingNamespaces() {
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app.debug.my-tag") == "com.cmuxterm.app.debug")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app.staging.rc") == "com.cmuxterm.app.staging")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.cmuxterm.app") == "com.cmuxterm.app")
    }

    @Test func historyFileURLNestsUnderNamespace() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let location = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app.debug.tag")
        #expect(location.namespace == "com.cmuxterm.app.debug")
        #expect(location.historyFileURL.path == "/tmp/appsupport/MyCMUX/com.cmuxterm.app.debug/browser_history.json")
    }

    @Test func legacyURLPresentOnlyWhenNamespaceDiffers() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let tagged = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app.debug.tag")
        #expect(tagged.legacyTaggedHistoryFileURL?.path == "/tmp/appsupport/com.cmuxterm.app.debug.tag/browser_history.json")

        let prod = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.cmuxterm.app")
        #expect(prod.legacyTaggedHistoryFileURL == nil)
    }
}
