import Foundation
import CmuxAuthRuntime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MacAuthCompositionLaunchOptionsTests {
    @Test func authProjectSwitchIsDetectedAndThenStabilizes() throws {
        let suiteName = "cmuxTests.macAuthProjectSwitch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MacAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: "production-project",
            buildDefaultProjectID: "development-project",
            defaults: defaults
        ))
        #expect(!MacAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: "production-project",
            buildDefaultProjectID: "development-project",
            defaults: defaults
        ))
        #expect(MacAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: "development-project",
            buildDefaultProjectID: "development-project",
            defaults: defaults
        ))
    }

    @Test func emptyEnvironmentDoesNotInjectCredentials() {
        let options = MacAuthComposition.launchOptions(environment: [:], includesDevAuth: true, authProjectSwitched: false)
        #expect(options.environment.isEmpty)
        #expect(!options.replaceStoredSessionWithAutoLogin)
        #expect(!options.shouldClearStoredSessionBeforePriming)
    }

    @Test(arguments: Array(0..<12))
    func launchMatrixPreservesRawEnvironment(_ input: Int) {
        let includesDevAuth = input & 1 != 0
        let switched = input & 2 != 0
        let clear = [nil, "0", "1"][input / 4]
        var environment = [
            "CMUX_DOGFOOD_STACK_EMAIL": "dummy@example.invalid",
            "CMUX_DOGFOOD_STACK_PASSWORD": "fake",
            "CMUX_AUTH_CREDENTIALS_FILE": "/not-read/dummy.env",
            "CMUX_DEV_AUTH_PROFILE": "personal",
            "CMUX_DEV_AUTH_CREDENTIALS_RESOLVED": "1",
            "CMUX_DEV_AUTH_REPLACE_SESSION": "1",
            "UNRELATED": "preserved",
        ]
        environment["CMUX_UITEST_CLEAR_AUTH"] = clear
        let options = MacAuthComposition.launchOptions(environment: environment,
            includesDevAuth: includesDevAuth, authProjectSwitched: switched)
        #expect(options.environment == environment)
        #expect(options.environment["CMUX_UITEST_STACK_EMAIL"] == nil)
        #expect(options.environment["CMUX_UITEST_STACK_PASSWORD"] == nil)
        #expect(!options.mockDataEnabled)
        #expect(options.includesDevAuth == includesDevAuth)
        #expect(options.clearAuthRequested == (clear == "1"))
        #expect(options.clearStaleAuthOnLaunch == switched)
        #expect(options.shouldClearStoredSessionBeforePriming == switched)
        #expect(!options.replaceStoredSessionWithAutoLogin)
    }

    @Test(arguments: [false, true], [false, true])
    func explicitUITestInputsKeepStoredTokenProtection(hasCredentials: Bool, hasStoredTokens: Bool) {
        let environment = ["CMUX_UITEST_STACK_EMAIL": "fixture@example.invalid", "CMUX_UITEST_STACK_PASSWORD": "fake"]
        let options = MacAuthComposition.launchOptions(environment: environment, includesDevAuth: true, authProjectSwitched: false)
        #expect(options.environment == environment)
        #expect(!options.replaceStoredSessionWithAutoLogin)
        #expect(!options.shouldClearStoredSessionBeforePriming)
        #expect(AuthLaunchOptions.shouldStartAutoLogin(hasCredentials: hasCredentials, hasStoredTokens: hasStoredTokens)
            == (hasCredentials && !hasStoredTokens))
    }
}
