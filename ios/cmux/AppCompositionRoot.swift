import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation
import SwiftUI
import cmuxFeature

/// Holds the de-singletonized graph the `cmuxApp` builds once at launch.
///
/// Owns the mobile runtime, auth composition, process-wide reachability monitor,
/// and mobile display settings. Everything below the app shell
/// receives these by injection instead of reaching for a singleton.
@MainActor
final class AppCompositionRoot {
    let runtime: CMUXMobileRuntime
    let auth: MobileAuthComposition
    let irx: MobileIrxRuntimeComposition
    let irohSettingsController: any CmxIrohSettingsControlling
    let irxDiscovery: MobileIrxDiscoveryProvider
    /// One build-compatibility policy shared by discovery, persistence, and
    /// connection validation. Keeping it here prevents composition paths from
    /// admitting different Mac app instances.
    let buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy
    let reachability: any ReachabilityProviding
    let signOutHook: MobileSignOutHook
    let analytics: any AnalyticsEmitting = NoopAnalytics()
    let displaySettings: MobileDisplaySettings
    /// App-lifetime keyboard frame record, injected into the view tree via
    /// `\.mobileKeyboardFrameTracker` so terminal hosts created or reattached
    /// mid-conversation recover keyboard transitions they were not installed
    /// for. Constructed here (not lazily in a view) so its record spans every
    /// host view lifetime.
    let keyboardFrameTracker = MobileKeyboardFrameTracker()
    /// The legacy connection-method choice used only by onboarding and migration UI.
    let connectionMethodStore: MobileConnectionMethodStore
    /// One-time BETA migration eligibility, snapshotted before launch writes.
    let autoConnectMigrationStore: MobileAutoConnectMigrationStore
    /// First-run onboarding progress, persisted to `UserDefaults.standard`.
    /// Built with `forceComplete` set when a UI-test mock harness or a dogfood
    /// auto-pair attach URL is active, so neither path is wedged behind the
    /// one-time onboarding screen.
    let onboardingStore: MobileOnboardingStore
    /// The process-wide tailnet detector behind the shell UI's read-only
    /// observing port, injected down so pairing and disconnected surfaces can
    /// explain a Tailscale-off phone.
    let tailscaleStatusMonitor: TailscaleStatusMonitorAdapter
    /// The bounded, structured connection log shared by the Iroh runtime and
    /// mobile shell. It is present in release builds, but its schema accepts
    /// only fixed categories and integer magnitudes, never terminal contents,
    /// credentials, peer identities, addresses, or free-form errors.
    let diagnosticLog: DiagnosticLog

    /// Owns UIKit lifecycle observers and removes them with the app graph.
    private let appLifecycleDiagnostics: MobileAppLifecycleDiagnostics

    /// The consolidated on-disk log pair: `cmux-app.log` (app-wide, including
    /// the mirrored string debug log) and `cmux-network.log` (network
    /// diagnostics). Fed by the diagnostic ring's event tap; always on, since
    /// structured events are privacy-safe by construction.
    let appLog: AppLog

    init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        irx: MobileIrxRuntimeComposition,
        irxDiscovery: MobileIrxDiscoveryProvider,
        buildCompatibilityPolicy: MobileMacBuildCompatibilityPolicy,
        reachability: any ReachabilityProviding,
        diagnosticLog: DiagnosticLog
    ) {
        #if DEBUG
        // Arm the durable debug log at launch: `.shared` is lazy, and without
        // this a run that never logs would create no file or crash capture.
        MobileDebugLog.shared.append("app launch · composition root initialized")
        #endif

        self.runtime = runtime
        self.auth = auth
        self.irx = irx
        self.irohSettingsController = MobileIrxSettingsController(irx: irx, diagnosticLog: diagnosticLog)
        self.irxDiscovery = irxDiscovery
        self.buildCompatibilityPolicy = buildCompatibilityPolicy
        self.reachability = reachability
        self.diagnosticLog = diagnosticLog
        let appLog = AppLog(
            appFileURL: AppLog.defaultAppLogFileURL,
            networkFileURL: AppLog.defaultNetworkLogFileURL,
            buildStamp: MobileDebugLog.buildStamp,
            supplementalAppLogURLs: { MobileDebugLog.logFileURLs },
            flushSupplementalAppLog: { await MobileDebugLog.shared.flush() },
            supplementalAppLogSnapshot: {
                await MobileDebugLog.shared.snapshotPersistedLogData()
            }
        )
        self.appLog = appLog
        diagnosticLog.setEventTap { event in
            appLog.ingest(event)
        }
        self.appLifecycleDiagnostics = MobileAppLifecycleDiagnostics(
            diagnosticLog: diagnosticLog
        )
        diagnosticLog.recordAppEvent(.appLaunched)
        // Mirror the string debug log into the app log file so one file holds
        // the whole in-app story in wall-clock order. The string sink keeps
        // its own privacy gating (DEBUG always, Release behind the verbose
        // opt-in), so this mirror never widens what gets persisted.
        Task {
            let sink = MobileDebugLog.shared.sink
            await sink.addLineObserver { [weak appLog] line in
                appLog?.mirrorAppLine(line)
            }
        }
        #if DEBUG
        // DEV: a devicectl launch with DEVICECTL_CHILD_CMUX_PRESENCE_BASE_URL
        // persists the isolated-worker override so later env-less cold
        // launches (push wakes) keep resolving it.
        PresenceClient.persistEnvironmentOverrideIfPresent()
        #endif
        self.signOutHook = MobileSignOutHook {
            let signingOutScope = auth.coordinator.authenticatedTeamScope
            return { _, _ in
                await irx.handleSignOut(ifCurrent: signingOutScope)
                await diagnosticLog.clear()
            }
        }
        // Main's display-settings owner intentionally keeps diagnostics out of
        // the preferences object. The app root still owns the shared log for
        // services that emit lifecycle events, while display preferences use
        // their injected defaults store only.
        self.displaySettings = MobileDisplaySettings()
        // Snapshot raw upgrade eligibility before either current-launch store is
        // constructed. The migration model persists pending/ineligible now and
        // never recomputes after onboarding or Settings writes. UI fixtures use
        // one isolated defaults suite for both pieces of durable state, so a
        // relaunch proves the production persistence path without touching the
        // simulator's normal connection preference.
        let connectionPreferenceDefaults: UserDefaults
        #if DEBUG
        if let fixture = AutoConnectMigrationUITestConfiguration(
            environment: ProcessInfo.processInfo.environment
        ) {
            guard let fixtureDefaults = UserDefaults(suiteName: fixture.defaultsSuiteName) else {
                preconditionFailure("Unable to create Auto-Connect migration UI-test defaults")
            }
            if fixtureDefaults.object(
                forKey: MobileAutoConnectMigrationStore.resolutionKey
            ) == nil {
                if let persistedConnectionMethod = fixture.persistedConnectionMethod {
                    fixtureDefaults.set(
                        persistedConnectionMethod.rawValue,
                        forKey: MobileConnectionMethodStore.methodKey
                    )
                } else {
                    fixtureDefaults.removeObject(
                        forKey: MobileConnectionMethodStore.methodKey
                    )
                }
                // Keep this DEBUG fixture key aligned with the immutable v1
                // schema so the UI test enters through real migration storage.
                let legacyResolutionKey = "dev.cmux.mobile.autoConnectIntroduction.v1"
                if let legacyResolution = fixture.legacyResolution {
                    fixtureDefaults.set(
                        legacyResolution.rawValue,
                        forKey: legacyResolutionKey
                    )
                } else {
                    fixtureDefaults.removeObject(forKey: legacyResolutionKey)
                }
                switch fixture.eligibility {
                case .eligible:
                    fixtureDefaults.set(
                        MobileOnboardingProgress.complete.rawValue,
                        forKey: MobileOnboardingStore.progressKey
                    )
                case .ineligible:
                    fixtureDefaults.removeObject(forKey: MobileOnboardingStore.progressKey)
                }
            }
            connectionPreferenceDefaults = fixtureDefaults
        } else {
            connectionPreferenceDefaults = .standard
        }
        #else
        connectionPreferenceDefaults = .standard
        #endif
        self.autoConnectMigrationStore = MobileAutoConnectMigrationStore(
            defaults: connectionPreferenceDefaults
        )
        self.connectionMethodStore = MobileConnectionMethodStore(
            defaults: connectionPreferenceDefaults,
            diagnosticLog: diagnosticLog
        )
        // Skip first-run onboarding when a UI-test mock harness
        // (`CMUX_UITEST_MOCK_DATA`/XCUITest) or a dogfood auto-pair attach URL is
        // active: those launches expect to land on sign-in / add-device / a live
        // workspace, not behind a manual tap-through. The dedicated onboarding
        // preview remains active so its relaunch test exercises real persistence.
        // `forceComplete` never writes the real install's persisted progress.
        #if DEBUG
        let onboardingPreviewEnabled = UITestConfig.onboardingPreviewEnabled
        #else
        let onboardingPreviewEnabled = false
        #endif
        let bypassOnboarding = (UITestConfig.mockDataEnabled && !onboardingPreviewEnabled)
            || UITestConfig.dogfoodAttachURL != nil
            || UITestConfig.attachURL != nil
        self.onboardingStore = MobileOnboardingStore(
            defaults: .standard,
            forceComplete: bypassOnboarding
        )
        self.tailscaleStatusMonitor = TailscaleStatusMonitorAdapter(monitor: TailscaleStatusMonitor())
        // Start auth only after the diagnostic tap is durable. Session restore
        // can complete during launch, and starting earlier would leave its
        // accepted events in the in-memory ring but absent from cmux-app.log.
        auth.start()
    }

    /// Bundle-owned build identity used in explicit diagnostic exports.
    /// Values come only from signed app metadata, never user input.
    static var diagnosticBuildStamp: String {
        DiagnosticReport.buildStamp(infoDictionary: Bundle.main.infoDictionary)
    }

    /// Records local lifecycle diagnostics and forwards lifecycle to Irx.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            #if DEBUG
            MobileLatencyTrace.stamp("scene.active")
            #endif
            diagnosticLog.recordAppEvent(.appForegrounded)
            connectionMethodStore.recordConfiguredMethodDiagnostic()
            Task { await irx.didBecomeActive() }
        case .inactive:
            diagnosticLog.recordAppEvent(.appBecameInactive)
        case .background:
            diagnosticLog.recordAppEvent(.appBackgrounded)
            Task { await irx.didEnterBackground() }
        @unknown default:
            break
        }
    }
}
