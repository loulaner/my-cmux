import XCTest

/// The UI-test runner owns device rotation; hosted unit tests are not authorized to send device UI events.
final class LocalTerminalRotationUITests: XCTestCase {
    @MainActor
    func testLiveTerminalSurvivesIPadRotation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "dev.cmux.ios.local-terminal-acceptance")
        app.launchArguments = ["--local-terminal-ui-acceptance"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let status = app.staticTexts["local-terminal-acceptance-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "ready-rotate"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed, status.label)
        capture(app, name: "synthetic-terminal-keyboard-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "passed-landscape"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 35), .completed, status.label)
        capture(app, name: "synthetic-terminal-keyboard-landscape")
        Thread.sleep(forTimeInterval: 5) // Allow the independent simctl compositor capture to observe the settled scene.
    }
    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
