import AppKit
import AVFoundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud welcome")
struct CloudWelcomeTests {
    @Test("the explicit welcome card selects the approved headline preview")
    @MainActor
    func explicitCardUsesHeadlinePreview() {
        let view = CloudWelcomeView(nextStep: .upgrade, onNotNow: {}, onNext: { _ in })
        #expect(view.posterHeadline == String(localized: "cloud.welcome.headline", defaultValue: "Cloud machines for your agents"))
        #expect(view.sliderShowsFeatureList)
        #expect(view.posterShowsTitle)
        #expect(view.posterShowsIcon)
        #expect(!view.showsNewBadge)
        #expect(!view.footerHasNotNow)
        let carousel = CloudWelcomeMediaCarousel(slides: CloudWelcomeSlide.all, mediaURL: { _ in nil })
        #expect(carousel.posterHeadline == view.posterHeadline)
    }

    @Test("Reduce Motion holds movies through selection, restart and attachment")
    @MainActor
    func reducedMotionOwnsPlayback() {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let player = AVPlayer()
        playback.attach(player)
        playback.setReduceMotion(true)
        #expect(playback.isPaused)
        playback.startNewSlide(at: 1)
        playback.restart()
        playback.setPaused(false)
        #expect(playback.isPaused)
        let replacement = AVPlayer()
        playback.attach(replacement)
        playback.setReduceMotion(false)
        #expect(!playback.isPaused)
        playback.setPaused(true)
        playback.setReduceMotion(true)
        playback.setReduceMotion(false)
        #expect(playback.isPaused)
    }

    @Test("a cancelled fallback deadline cannot advance the slide")
    @MainActor
    func cancelledDeadlineDoesNotAdvance() async {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let deadline = Task { await playback.waitForAdvance(after: 60) }
        await Task.yield()
        deadline.cancel()
        #expect(await deadline.value == false)
    }

    @Test("restarting a failed movie preserves its fallback transition")
    @MainActor
    func restartingFailedMovieKeepsFailureState() async {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let player = AVPlayer()
        playback.attach(player)
        playback.didFail(player)
        #expect(playback.movieFailed)
        let deadline = Task { await playback.waitForAdvance(after: 60) }
        await Task.yield()
        let revision = playback.revision
        playback.restart()
        #expect(playback.movieFailed)
        #expect(playback.revision == revision + 1)
        deadline.cancel()
        #expect(await deadline.value == false)
    }

    @Test("welcome owns close instead of the terminal behind it")
    @MainActor
    func welcomeOwnsCloseShortcut() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloud.welcome")
        #expect(cmuxWindowShouldOwnCloseShortcut(window))
    }

    @Test("any existing marker is seen; explicit presentation writes only the current marker",
          arguments: [nil, "0.64.25", "0.65.0", "", "0.65.1"] as [String?])
    func campaignMarkerUpgradeAndNoRepeat(previousMarker: String?) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.cloud.welcome.seen")
        if let previousMarker {
            defaults.set(previousMarker, forKey: CloudWelcomeWindowController.seenVersionDefaultsKey)
        }
        #expect(CloudWelcomeWindowController.hasSeenWelcome(in: defaults) == (previousMarker != nil))
        CloudWelcomeWindowController.markCampaignSeen(in: defaults)
        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == "0.65.1")
        #expect(CloudWelcomeWindowController.hasSeenWelcome(in: defaults))
        #expect(defaults.bool(forKey: "cmux.cloud.welcome.seen"), "The historical boolean is not deleted or migrated")
    }

    @Test("the one prominent button is the next step for this account")
    func nextStepFollowsSignInAndPlan() {
        // Signed out reads like Free: Upgrade to Pro.
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: false, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: true, isPro: true) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: false, isPro: false) == .openCloud)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: true) == .enable)

        // A free account that has accepted membership in a shared team can use
        // that team's Cloud scope without buying a personal Pro subscription.
        #expect(CloudWelcomeNextStep.resolve(
            isAuthenticated: true,
            isPlanKnown: true,
            isPro: false,
            hasCloudTeamAccess: true
        ) == .enable)
    }

    @Test("only an additional accepted team opens Cloud for a free personal account")
    func sharedTeamAccessRequiresMoreThanPersonalTeam() {
        #expect(!CloudWelcomeNextStep.hasSharedTeamAccess(availableTeamCount: 0))
        #expect(!CloudWelcomeNextStep.hasSharedTeamAccess(availableTeamCount: 1))
        #expect(CloudWelcomeNextStep.hasSharedTeamAccess(availableTeamCount: 2))
    }

    @Test("a shared team does not turn a personal free scope into Pro")
    func sharedTeamAccessOnlyOpensCloud() {
        #expect(!CloudMachinesEnablementView.shouldRequirePro(
            isPlanKnown: true,
            isProActive: false,
            hasCloudTeamAccess: true
        ))
        #expect(CloudMachinesEnablementView.shouldRequirePro(
            isPlanKnown: true,
            isProActive: false,
            hasCloudTeamAccess: false
        ))
    }

    @Test("feature clips keep their stable product order")
    func featureClipIDsAreStable() {
        #expect(CloudWelcomeSlide.all.map(\.id) == ["spin-up", "displays", "invite", "team", "keeps-running"])
        #expect(Set(CloudWelcomeSlide.all.map(\.id)).count == CloudWelcomeSlide.all.count)
    }

    @Test("every welcome feature resolves a bundled clip")
    func everyFeatureClipIsBundled() {
        for slide in CloudWelcomeSlide.all {
            #expect(CloudWelcomeMediaCarousel.bundledMediaURL(slide) != nil, "Missing bundled clip for \(slide.id)")
        }
    }

    @Test("short clips dwell long enough to read before autoplay advances")
    func shortMovieDwell() {
        #expect(!CloudWelcomeMediaCarousel.shouldAdvanceAfterMovie(elapsed: 3.99))
        #expect(CloudWelcomeMediaCarousel.shouldAdvanceAfterMovie(elapsed: 4))
    }

    @Test("feature clips preserve the full recorded frame")
    @MainActor
    func featureClipVideoGravityPreservesRecordedFrame() throws {
        let url = try #require(
            CloudWelcomeMediaCarousel.bundledMediaURL(CloudWelcomeSlide.all[0])
        )
        let playback = CloudWelcomeMediaCarousel.Playback()
        let movieView = CloudWelcomeMediaCarousel.Player.MovieView(url: url, playback: playback)

        #expect((movieView.layer as? AVPlayerLayer)?.videoGravity == .resizeAspect)
    }

    @Test("Cloud creation actions introduce Cloud while it is off or signed out")
    func creationGate() {
        func gate(_ available: Bool, _ enabled: Bool, _ canRun: Bool?, authInProgress: Bool = false) -> CloudCreationGate {
            CloudCreationGate.resolve(
                isAvailable: available, isEnabled: enabled,
                canRunCloudOperations: canRun, isAuthInProgress: authInProgress
            )
        }
        #expect(gate(true, false, false) == .introduceCloud)
        #expect(gate(true, false, false, authInProgress: true) == .introduceCloud)
        #expect(gate(true, true, false) == .introduceCloud)
        #expect(gate(true, true, true) == .proceed)
        // A session still restoring is not signed out yet.
        #expect(gate(true, true, false, authInProgress: true) == .proceed)
        // Before app composition there is no operation answer to act on.
        #expect(gate(true, true, nil) == .proceed)
        // Managed policy that disables Cloud keeps the action's own handling.
        #expect(gate(false, false, false) == .proceed)
    }

    @Test("Enable from the welcome continues the original action only once Cloud is enabled")
    @MainActor
    func resumeAfterEnable() async throws {
        struct PreparationFailed: Error {}
        let suiteName = "CloudWelcomeTests.resume.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let succeeding = CloudActivationCoordinator(
            defaults: defaults, notificationCenter: NotificationCenter(),
            isAvailable: { true }, prepare: {}, observeChanges: false
        )
        succeeding.enable()
        var resumed = 0
        await CloudWelcomeWindowController.resume({ resumed += 1 }, after: succeeding)
        #expect(resumed == 1)

        defaults.removeObject(forKey: CloudActivationCoordinator.activationKey)
        let failing = CloudActivationCoordinator(
            defaults: defaults, notificationCenter: NotificationCenter(),
            isAvailable: { true }, prepare: { throw PreparationFailed() }, observeChanges: false
        )
        failing.enable()
        await CloudWelcomeWindowController.resume({ resumed += 1 }, after: failing)
        #expect(failing.state == .failed(.serviceUnavailable))
        #expect(resumed == 1)
    }
}
