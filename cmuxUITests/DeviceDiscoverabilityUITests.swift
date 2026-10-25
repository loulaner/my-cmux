import XCTest

/// Exercises shared preference actions, confirmation, and persistence in Settings.
final class DeviceDiscoverabilityUITests: SettingsUITestCase {
    private let incomingKey = "devices.incomingAccess.enabled"
    private let discoveryKey = "devices.discovery.enabled"
    override func setUp() {
        super.setUp()
        resetDefaults([incomingKey, discoveryKey])
    }

    override func tearDown() {
        resetDefaults([incomingKey, discoveryKey])
        super.tearDown()
    }

    func testSettingsConfirmsOnlyIncomingEnableAndPersistsBothChoices() {
        let app = launchDevicesApp()
        defer {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 10)
        }
        let window = openSettings(app)
        navigate(window, to: "Devices")
        let settingsIncoming = toggle(window, id: "SettingsComputersIncomingAccessToggle")
        let settingsDiscovery = toggle(window, id: "SettingsComputersDiscoveryToggle")
        if isOn(settingsIncoming) {
            settingsIncoming.click()
            XCTAssertTrue(poll(timeout: 5) { !self.isOn(settingsIncoming) })
        }
        if isOn(settingsDiscovery) {
            settingsDiscovery.click()
            XCTAssertTrue(poll(timeout: 5) { !self.isOn(settingsDiscovery) })
        }
        XCTAssertEqual(settingsIncoming.label, "Make this Mac discoverable")
        XCTAssertEqual(settingsDiscovery.label, "Discover other devices")

        settingsIncoming.click()
        assertConfirmation(app)
        capture(app, "discoverability-confirmation")
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(isOn(settingsIncoming))

        settingsIncoming.click()
        assertConfirmation(app)
        // Escape is the native dialog's Cancel action.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(isOn(settingsIncoming))

        settingsIncoming.click()
        assertConfirmation(app)
        app.sheets.buttons["Make Discoverable"].firstMatch.click()
        XCTAssertTrue(poll(timeout: 5) { self.isOn(settingsIncoming) })
        XCTAssertEqual(settingsIncoming.label, "Hide this Mac from My Devices")
        XCTAssertFalse(isOn(settingsDiscovery))
        settingsIncoming.click()
        XCTAssertTrue(poll(timeout: 5) { !self.isOn(settingsIncoming) })
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertEqual(settingsIncoming.label, "Make this Mac discoverable")

        settingsDiscovery.click()
        XCTAssertTrue(poll(timeout: 5) { self.isOn(settingsDiscovery) })
        XCTAssertEqual(settingsDiscovery.label, "Stop discovering other devices")
        XCTAssertFalse(app.sheets.firstMatch.exists)
        closeSettings(app, window)
        let reopened = openSettings(app)
        navigate(reopened, to: "Devices")
        XCTAssertTrue(isOn(toggle(reopened, id: "SettingsComputersDiscoveryToggle")))
        XCTAssertFalse(isOn(toggle(reopened, id: "SettingsComputersIncomingAccessToggle")))
        closeSettings(app, reopened)
    }

    private func assertConfirmation(_ app: XCUIApplication) {
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertTrue(app.sheets.staticTexts["Make this Mac discoverable?"].exists)
        XCTAssertTrue(app.sheets.staticTexts[
            "Other Macs signed in to your cmux account may discover this Mac and connect to its workspaces. Do you want to continue?"
        ].exists)
    }

    private func launchDevicesApp() -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_AUTH_USER_ID"] = "discoverability-fixture"
        app.launchEnvironment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] = "1"
        app.launchArguments += settingsLaunchArguments + [
            "-cloud.beta.machines.enabled", "<true/>",
            "-fileExplorer.isVisible", "YES",
            "-workspacePresentationMode", "standard",
            "-rightSidebar.mode", "files",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
