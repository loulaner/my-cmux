import AppKit
import CmuxCloud
import CmuxProductAnalytics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Upgrade actions", .serialized, .exclusiveAppContext)
struct UpgradeAnalyticsTests {
    @Test("The sidebar Upgrade action opens pricing with its source")
    func sidebarBadge() {
        var opened: [ProUpgradeSource] = []
        let actions = ProBadgeActions(openPricing: { opened.append($0) })
        actions.upgrade()
        #expect(opened == [.sidebarBadge])
    }

    @Test("The welcome Upgrade action preserves its step and checkout source",
          arguments: [CloudWelcomeTrigger.launchAnnouncement, .newCloudWorkspace, .newCloudMachine])
    func welcomeUpgrade(trigger: CloudWelcomeTrigger) throws {
        let suite = "UpgradeAnalyticsTests.welcome.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var performed: [CloudWelcomeNextStep] = []
        var opened: [ProUpgradeSource] = []
        let controller = CloudWelcomeWindowController(
            defaults: defaults,
            nextStep: { .upgrade },
            performNextStep: { step, _ in
                performed.append(step)
                ProUpgradePresenter.present(source: .cloudWelcome, open: { opened.append($0) })
            }
        )
        defer { controller.dismiss() }
        controller.present(over: nil, trigger: trigger)
        controller.handleNext(.upgrade)
        #expect(performed == [.upgrade])
        #expect(opened == [.cloudWelcome])
        let url = ProUpgradePresenter.checkoutURL(source: .cloudWelcome)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains { $0.name == "cmux_source" && $0.value == ProUpgradeSource.cloudWelcome.rawValue } == true)
    }

    @Test("Enable and sign-in route once; dismiss actions do not perform a step")
    func welcomeOtherOutcomes() throws {
        for (step, act) in [(CloudWelcomeNextStep.enable, "next"), (.signIn, "next"),
                            (.upgrade, "notNow"), (.upgrade, "close")] {
            let suite = "UpgradeAnalyticsTests.outcome.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var performed: [CloudWelcomeNextStep] = []
            let controller = CloudWelcomeWindowController(
                defaults: defaults, nextStep: { step },
                performNextStep: { offered, _ in performed.append(offered) }
            )
            controller.present(over: nil, trigger: .newCloudMachine)
            switch act {
            case "next": controller.handleNext(step)
            case "notNow": controller.handleNotNow()
            default: controller.dismiss()
            }
            controller.dismiss()
            #expect(performed == (act == "next" ? [step] : []))
        }
    }

    @Test("Cloud reveals before introduction, and unavailable Cloud performs no action")
    func sidebarCloudButton() {
        for (available, enabled, expected) in [
            (true, true, ["reveal"]), (true, false, ["reveal", "introduce"]),
            (false, false, []), (false, true, [])
        ] {
            var actions: [String] = []
            SidebarCloudButtonAction(
                isAvailable: { available }, isEnabled: { enabled },
                revealMachines: { actions.append("reveal") },
                presentIntroduction: { actions.append("introduce") }
            ).perform()
            #expect(actions == expected)
        }
    }
}

@MainActor
@Suite("Machine create refusal recovery", .serialized)
struct MachineCreateAnalyticsTests {
    @Test("A refused create keeps its failure code and retries to a real created receipt")
    func refusalThenRetry() throws {
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let coordinator = MachineCreateCoordinator(
            notifier: { _ in }, notificationCenter: NotificationCenter()
        )
        coordinator.start(MachineCreateCoordinatorTests.newMachineRequest(), launch: launches.launch)
        let id = try #require(coordinator.operations.first?.id)
        launches.complete(status: 1, output: "Error: limit", refusalCode: "vm_active_limit_exceeded")
        #expect(coordinator.operation(id: id)?.refusalCode == "vm_active_limit_exceeded")
        #expect(!coordinator.hasRunningOperations)
        #expect(coordinator.retry(id))
        #expect(launches.arguments.count == 2)
        #expect(coordinator.operation(id: id)?.isRunning == true)
        #expect(coordinator.operation(id: id)?.refusalCode == nil)
        let workspaceID = UUID()
        launches.complete(status: 0, output: "OK machine=m1", workspaceID: workspaceID, machineID: "m1")
        #expect(coordinator.operations.isEmpty)
        #expect(coordinator.lastFinished?.outcome == .created(machineID: "m1", workspaceID: workspaceID))
    }
}
