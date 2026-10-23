#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A short product tour presented after sign-in, ending in same-account
/// computer discovery with explicit Mac-side pairing opt-in.
struct OnboardingFlowView: View {
    let context: OnboardingContext
    let isAuthenticated: Bool
    let connectionPhase: OnboardingConnectionPhase
    let connectionMethod: MobileConnectionMethod
    let keepAwakeOffer: OnboardingKeepAwakeOffer?
    let onSelectConnectionMethod: (MobileConnectionMethod) -> Void
    let onReachedConnection: () -> Void
    let onSkip: () -> Void
    let onRetryConnection: () -> Void
    let onStartTailscalePairing: () -> Void
    let onSetKeepAwake: (Bool) async -> Bool
    let onComplete: () -> Void

    @State private var stage: OnboardingStage
    @State private var didReachConnection = false
    @State private var didRecordStart = false
    @Environment(\.analytics) private var analytics
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog

    init(
        initialStage: OnboardingStage,
        context: OnboardingContext,
        isAuthenticated: Bool,
        connectionPhase: OnboardingConnectionPhase,
        connectionMethod: MobileConnectionMethod = .automatic,
        keepAwakeOffer: OnboardingKeepAwakeOffer? = nil,
        onSelectConnectionMethod: @escaping (MobileConnectionMethod) -> Void = { _ in },
        onReachedConnection: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRetryConnection: @escaping () -> Void,
        onStartTailscalePairing: @escaping () -> Void,
        onSetKeepAwake: @escaping (Bool) async -> Bool = { _ in false },
        onComplete: @escaping () -> Void
    ) {
        self.context = context
        self.isAuthenticated = isAuthenticated
        self.connectionPhase = connectionPhase
        self.connectionMethod = connectionMethod
        self.keepAwakeOffer = keepAwakeOffer
        self.onSelectConnectionMethod = onSelectConnectionMethod
        self.onReachedConnection = onReachedConnection
        self.onSkip = onSkip
        self.onRetryConnection = onRetryConnection
        self.onStartTailscalePairing = onStartTailscalePairing
        self.onSetKeepAwake = onSetKeepAwake
        self.onComplete = onComplete
        _stage = State(initialValue: initialStage)
    }

    var body: some View {
        OnboardingSceneContainer(
            stage: stage,
            chrome: chrome,
            onBack: handleBack,
            onSkip: skip,
            onPrimary: handlePrimary,
            onSecondary: handleSecondary,
            pageContent: OnboardingPageViewport(
                stage: stage,
                stages: OnboardingStage.allCases,
                onNavigate: { navigate(to: $0) }
            ) { pageStage in
                page(for: pageStage)
            }
        )
        .interactiveDismissDisabled()
        .onAppear {
            if !didRecordStart {
                didRecordStart = true
                diagnosticLog?.recordAppEvent(.onboardingStarted)
            }
            captureSceneViewed()
            reachConnectionIfNeeded()
        }
        .onChange(of: stage) { _, _ in
            captureSceneViewed()
            reachConnectionIfNeeded()
        }
        .onChange(of: isAuthenticated) { _, isNowAuthenticated in
            guard stage == .connect else { return }
            captureSceneViewed()
            if isNowAuthenticated {
                onReachedConnection()
            }
        }
    }

    private var chrome: OnboardingSceneChrome {
        OnboardingSceneChrome(
            stage: stage,
            isAuthenticated: isAuthenticated,
            connectionPhase: connectionPhase,
            connectionMethod: connectionMethod
        )
    }

    @ViewBuilder
    private func page(for pageStage: OnboardingStage) -> some View {
        switch pageStage {
        case .agents:
            OnboardingAgentsView()
        case .notifications:
            OnboardingNotificationsView()
        case .pairing:
            OnboardingPairingView()
        case .connect:
            OnboardingConnectionView(
                phase: connectionPhase,
                connectionMethod: connectionMethod,
                onSelectConnectionMethod: selectConnectionMethod,
                keepAwakeOffer: keepAwakeOffer,
                onSetKeepAwake: setKeepAwake
            )
        }
    }

    private func handleBack() {
        if let previous = stage.previous { navigate(to: previous) }
    }

    private func handlePrimary() {
        switch stage {
        case .agents, .notifications, .pairing:
            if let next = stage.next { navigate(to: next) }
        case .connect:
            if isAuthenticated {
                finishOrRetry()
            } else {
                finishBeforeAuthentication()
            }
        }
    }

    private func reachConnectionIfNeeded() {
        guard stage == .connect, !didReachConnection else { return }
        didReachConnection = true
        onReachedConnection()
    }

    private func navigate(to destination: OnboardingStage) {
        guard destination != stage else { return }
        stage = destination
    }

    private func skip() {
        diagnosticLog?.recordAppEvent(.onboardingSkipped)
        analytics.capture("ios_onboarding_skipped", eventProperties)
        onSkip()
    }

    private func finishOrRetry() {
        switch connectionPhase {
        case .idle:
            if connectionMethod == .tailscale {
                startTailscalePairing()
            } else {
                diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
                onRetryConnection()
            }
        case .searching:
            break
        case .fallback:
            if connectionMethod == .tailscale {
                startTailscalePairing()
            } else {
                diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
                analytics.capture("ios_onboarding_connection_retried", eventProperties)
                onRetryConnection()
            }
        case .ready:
            diagnosticLog?.recordAppEvent(.onboardingCompleted)
            analytics.capture("ios_onboarding_completed", eventProperties)
            onComplete()
        }
    }

    private func handleSecondary() {
        guard connectionMethod == .tailscale, connectionPhase == .fallback else { return }
        diagnosticLog?.recordAppEvent(.onboardingConnectionRetried)
        analytics.capture("ios_onboarding_connection_retried", eventProperties)
        onRetryConnection()
    }

    private func setKeepAwake(_ enabled: Bool) async {
        var properties = eventProperties
        properties["enabled"] = .bool(enabled)
        analytics.capture("ios_onboarding_keep_awake_set", properties)
        let confirmed = await onSetKeepAwake(enabled)
        if !confirmed {
            properties["enabled"] = .bool(!enabled)
            analytics.capture("ios_onboarding_keep_awake_reverted", properties)
        }
    }

    private func selectConnectionMethod(_ method: MobileConnectionMethod) {
        guard method != connectionMethod else { return }
        diagnosticLog?.recordAppEvent(.onboardingConnectionMethodChanged)
        var properties = eventProperties
        properties["connection_method"] = .string(method.rawValue)
        analytics.capture("ios_onboarding_connection_method_selected", properties)
        let shouldStartTailscalePairing =
            method == .tailscale && connectionPhase == .ready
        withAnimation(.smooth(duration: 0.25)) {
            onSelectConnectionMethod(method)
        }
        // A ready Iroh connection must not turn a Tailscale selection into an
        // accidental onboarding completion. Pair the newly selected route now,
        // while leaving the existing ready state untouched for other changes.
        if shouldStartTailscalePairing {
            startTailscalePairing()
        }
    }

    private func startTailscalePairing() {
        diagnosticLog?.recordAppEvent(.onboardingPairingStarted)
        var properties = eventProperties
        properties["source"] = .string("tailscale_choice")
        analytics.capture("ios_onboarding_pairing_started", properties)
        onStartTailscalePairing()
    }

    private func finishBeforeAuthentication() {
        analytics.capture("ios_onboarding_tour_completed", eventProperties)
        onComplete()
    }

    private func captureSceneViewed() {
        diagnosticLog?.recordAppEvent(.onboardingStageViewed)
        var properties = eventProperties
        properties["surface"] = .string(stage.analyticsValue)
        analytics.capture("ios_onboarding_scene_viewed", properties)
    }

    private var eventProperties: [String: AnalyticsValue] {
        [
            "context": .string(context.rawValue),
            "stage": .string(stage.analyticsValue)
        ]
    }
}
#endif
