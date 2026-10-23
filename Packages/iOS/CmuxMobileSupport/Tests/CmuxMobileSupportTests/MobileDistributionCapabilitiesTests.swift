import Testing
@testable import CmuxMobileSupport

struct MobileDistributionCapabilitiesTests {
    @Test func personalArtifactOmitsOptionalServices() {
        let capabilities = MobileDistributionCapabilities(infoDictionary: ["CMUXPersonalBuild": true])
        #expect(!capabilities.supportsOAuth)
        #expect(!capabilities.supportsPush)
    }

    @Test func existingDistributionsRetainTheirBehavior() {
        let cases: [[String: Any]] = [[:], ["CMUXPersonalBuild": false]]
        for metadata in cases {
            let capabilities = MobileDistributionCapabilities(infoDictionary: metadata)
            #expect(capabilities.supportsOAuth)
            #expect(capabilities.supportsPush)
        }
    }
}
