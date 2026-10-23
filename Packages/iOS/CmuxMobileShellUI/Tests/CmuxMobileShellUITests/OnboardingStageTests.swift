import CmuxMobileShellModel
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingStageTests {
    @Test func tourNavigatesFourStagesInBothDirections() {
        let stages: [OnboardingStage] = [.agents, .notifications, .pairing, .connect]
        #expect(OnboardingStage.allCases == stages)
        #expect(stages.map(\.position) == [1, 2, 3, 4])
        #expect(stages.map(\.analyticsValue) == ["agents", "notifications", "pairing", "connect"])
        #expect(stages.map(\.next) == [.notifications, .pairing, .connect, nil])
        #expect(stages.map(\.previous) == [nil, .agents, .notifications, .pairing])
    }

    @Test func durableMilestonesRemainCompatible() {
        #expect(MobileOnboardingProgress(rawValue: "welcome") == .welcome)
        #expect(MobileOnboardingProgress(rawValue: "connect") == .connect)
        #expect(MobileOnboardingProgress(rawValue: "complete") == .complete)
        #expect(MobileOnboardingProgress(rawValue: "push") == nil)
    }
}
