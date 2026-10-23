import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct AbsentExternalHostTests {
    @Test func oldCloudHostWithoutSourceRejectsCreateWithoutLocalFallback() async throws {
        let suite = "AbsentExternalHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MobileShellComposite(
            workspaces: [],
            clientIDRepository: MobileClientIDRepository(defaults: defaults, environment: [:]),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        let result = await store.createExternalHostWorkspace(onHost: "cmux-cloud\u{1D}old-vm")
        guard case .failure(.notConnected) = result else {
            Issue.record("Missing external source must reject, not create locally")
            return
        }
        #expect(store.workspaces.isEmpty)
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.externalHostSummaries.isEmpty)
    }
}
