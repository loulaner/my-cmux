import CmuxCloud
import CMUXAuthCore
import CmuxAuthRuntime
import AppKit
import Foundation
import Network
import StackAuth

/// The macOS auth composition root.
///
/// Constructs the de-singletonized auth graph once at app startup, mirroring
/// the iOS `MobileAuthComposition`: the keychain/file fallback token store, a
/// `StackClientApp` over it (wrapped in ``CmuxAuthRuntime/StackAuthClient``),
/// the shared ``CmuxAuthRuntime/AuthCoordinator`` bound to the historical mac
/// defaults keys, and the ``HostBrowserSignInFlow``. Replaces
/// `AuthManager.shared`.
@MainActor
struct MacAuthComposition {
    /// The shared auth orchestrator (session state, tokens, teams).
    let coordinator: AuthCoordinator
    /// Recognizes/parses auth callback URLs (AppDelegate URL routing).
    let callbackRouter: AuthCallbackRouter
    /// The token store the Stack client persists through.
    let tokenStore: any StackAuthTokenStoreProtocol
    /// The hosted-browser sign-in flow used by app-session recovery.
    let browserSignIn: HostBrowserSignInFlow
    /// Bridges the native Stack session into explicitly opened cmux web panes.
    let browserAppSession: BrowserAppSessionController
    /// Shared observable account projection used by Settings and sidebar UI.
    let accountFlow: HostAccountFlow
    /// Reconciles Cloud transports with the coordinator's selected team.
    let cloudTeamScopeObserver: CloudTeamScopeObserver
    let teamScopeRecoveryTriggers: MacAuthTeamScopeRecoveryTriggers

    /// Build the auth graph.
    /// - Parameters:
    ///   - environment: The process environment (UI-test launch options).
    ///   - defaults: Persistence for the cached user / has-tokens flag /
    ///     selected team (historical `cmux.auth.*` keys).
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let resolvedAuthEnvironment = AuthEnvironment.resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let stackProjectID = AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let stackPublishableClientKey = AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let tokenStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier)
            ),
            fallback: FileStackTokenStore(directory: Self.credentialsDirectory(bundleIdentifier: bundleIdentifier))
        )
        self.tokenStore = tokenStore

        let userCache = CMUXAuthIdentityStore(
            keyValueStore: defaults,
            key: "cmux.auth.cachedUser"
        )
        let sessionCache = CMUXAuthSessionCache(
            keyValueStore: defaults,
            key: "cmux.auth.hasTokens"
        )
        // One-time migration: the deleted AuthManager never wrote a has-tokens
        // flag. Prime it from the cached user so the first post-migration
        // launch primes as "restoring" instead of flashing signed-out while
        // the stored session validates.
        if defaults.object(forKey: "cmux.auth.hasTokens") == nil,
           (try? userCache.load()) != nil {
            sessionCache.setHasTokens(true)
        }

        let config = AuthConfig(
            stack: CMUXAuthConfig(
                projectId: stackProjectID,
                publishableClientKey: stackPublishableClientKey
            ),
            magicLinkCallbackURL: AuthEnvironment.websiteOrigin
                .appendingPathComponent("auth/callback", isDirectory: false)
                .absoluteString,
            apiBaseURL: AuthEnvironment.apiBaseURL.absoluteString
        )
        let client = StackAuthClient(
            config: config,
            tokenStore: .custom(tokenStore),
            baseURL: AuthEnvironment.stackBaseURL.absoluteString,
            noAutomaticPrefetch: true
        )
        let authProjectSwitched = Self.detectAuthProjectSwitch(
            resolvedProjectID: stackProjectID,
            buildDefaultProjectID: AuthEnvironment.resolvedStackProjectID(
                environment: [:],
                isDebugBuild: Self.isDebugBuild
            ),
            defaults: defaults
        )
        let includesDevAuth = Self.includesDevAuth(
            resolvedAuthEnvironment: resolvedAuthEnvironment
        )
        let launch = Self.launchOptions(
            environment: environment,
            includesDevAuth: includesDevAuth,
            authProjectSwitched: authProjectSwitched
        )

        let anchor = AuthPresentationContextProvider()
        let browserAppSessionSignInRelay = BrowserAppSessionSignInRelay()
        let coordinator = AuthCoordinator(
            client: Self.uiTestAuthClient(wrapping: client, environment: environment),
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: CMUXAuthTeamSelectionStore(
                keyValueStore: defaults,
                key: "cmux.auth.selectedTeamID"
            ),
            anchor: anchor,
            config: config,
            launch: launch,
            onSessionWillTransition: {
                browserAppSessionSignInRelay.sessionWillTransition()
            },
            onSignedIn: {
                await CmuxTuiSurfaceProviderRegistry.shared.resumeAfterSignIn()
                await browserAppSessionSignInRelay.signedIn()
            }
        )
        self.coordinator = coordinator
        let browserAppSession = BrowserAppSessionController(
            coordinator: coordinator,
            webOrigin: AuthEnvironment.appSessionHandoffOrigin,
            projectID: stackProjectID,
            defaults: defaults
        )
        self.browserAppSession = browserAppSession
        browserAppSessionSignInRelay.bind(
            beginTransition: { [weak browserAppSession] in
                browserAppSession?.beginAuthTransition()
            },
            resume: { [weak browserAppSession] in
                await browserAppSession?.resumeAfterSignIn()
            }
        )
        let callbackRouter = AuthCallbackRouter(
            extraAllowedScheme: AuthEnvironment.callbackScheme
        )
        self.callbackRouter = callbackRouter
        // Sign-out deletes only this build's tunnels. Their fingerprints are
        // read when sign-out begins, before Cloud teardown removes the local
        // credentials that record them.
        let signOutTunnelRoles = SignOutTunnelRoles()
        let browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: callbackRouter,
            makeSignInURL: { AuthEnvironment.signInURL(callbackState: $0) },
            callbackScheme: { AuthEnvironment.callbackScheme },
            openExternalURL: { NSWorkspace.shared.open($0) },
            approveUnsolicitedCallback: { await UnsolicitedAuthCallbackApprovalPrompt.present($0) },
            beginSignOut: {
                // Tear down local Cloud VM workspaces before the coordinator
                // clears auth. This closes live WebSockets, removes persisted
                // reconnect configuration, and prevents a signed-out Mac (or
                // a paired phone still connected to it) from retaining a
                // usable remote surface.
                signOutTunnelRoles.roles = VMTunnelManager.storedRoles()
                AppDelegate.shared?.prepareCloudVMAccessForSignOut()
                browserAppSession.beginAuthTransition()
                MobileHostIrxRuntime.shared.beginSignOutPreparation()
            },
            localSignOut: {
                await browserAppSession.clearCmuxWebSession()
            },
            onSignedOut: { accessToken, refreshToken in
                let roles = await MainActor.run { signOutTunnelRoles.take() }
                await VMClient.revokeTunnelRoles(
                    roles,
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
                // Endpoint/preview credentials are separate from Stack Auth;
                // revoke them with the captured pre-clear token pair before
                // the coordinator's server-session revocation tail completes.
                await VMClient.revokeEndpointLeases(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            }
        )
        self.browserSignIn = browserSignIn
        self.accountFlow = HostAccountFlow(
            coordinator: coordinator,
            browserSignIn: browserSignIn
        )
        self.teamScopeRecoveryTriggers = MacAuthTeamScopeRecoveryTriggers(coordinator: coordinator)
        self.cloudTeamScopeObserver = CloudTeamScopeObserver(auth: coordinator) { isSameAccount in
            AppDelegate.shared?.prepareCloudVMAccessForTeamSwitch(isSameAccount: isSameAccount)
        }
    }

    /// Begin asynchronous session restore. Call once after construction, at
    /// the composition root.
    func start() {
        cloudTeamScopeObserver.start()
        teamScopeRecoveryTriggers.start()
        coordinator.start()
    }

    /// Where the file-fallback token store persists, namespaced by bundle id
    /// (matching the pre-package layout so existing sessions survive).
    private static func credentialsDirectory(bundleIdentifier: String?) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("MyCMUX", isDirectory: true)
            .appendingPathComponent(bundleIdentifier ?? "com.loulaner.mycmux", isDirectory: true)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// DEBUG UI tests can serve fixture team membership around the live client.
    private static func uiTestAuthClient(
        wrapping client: any AuthClient,
        environment: [String: String]
    ) -> any AuthClient {
        #if DEBUG
        UITestFixtureTeamsAuthClient.wrapping(client, environment: environment)
        #else
        client
        #endif
    }

    private static func includesDevAuth(
        resolvedAuthEnvironment: CMUXAuthEnvironment
    ) -> Bool {
        isDebugBuild && resolvedAuthEnvironment == .development
    }

    nonisolated static let storedStackProjectIDKey = "cmux.auth.stackProjectID"

    /// Keep cached identities and Stack tokens from crossing projects when one
    /// tagged Debug bundle is rebuilt with `--prod-auth`, or switched back.
    nonisolated static func detectAuthProjectSwitch(
        resolvedProjectID: String,
        buildDefaultProjectID: String,
        defaults: UserDefaults
    ) -> Bool {
        let previous = defaults.string(forKey: storedStackProjectIDKey) ?? buildDefaultProjectID
        defaults.set(resolvedProjectID, forKey: storedStackProjectIDKey)
        return previous != resolvedProjectID
    }

    /// Combines explicit launch inputs without resolving or injecting credentials.
    nonisolated static func launchOptions(
        environment: [String: String],
        includesDevAuth: Bool,
        authProjectSwitched: Bool
    ) -> AuthLaunchOptions {
        AuthLaunchOptions(
            clearAuthRequested: environment["CMUX_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: false,
            environment: environment,
            includesDevAuth: includesDevAuth,
            clearStaleAuthOnLaunch: authProjectSwitched
        )
    }

}

/// Retries a missing team scope when a retry is likely to succeed.
///
/// macOS has no foreground revalidation like iOS, and a login-item launch
/// often runs before the network is up. The coordinator's backoff loop is the
/// guarantee; these signals (network path restored, system wake, app
/// activation) only shorten the wait. Each call is a no-op for a healthy
/// session.
@MainActor
final class MacAuthTeamScopeRecoveryTriggers {
    private let coordinator: AuthCoordinator
    private let pathMonitor = NWPathMonitor()
    private var tasks: [Task<Void, Never>] = []

    init(coordinator: AuthCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard tasks.isEmpty else { return }
        let notifications: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
        ]
        for (center, name) in notifications {
            tasks.append(Task { @MainActor [weak self] in
                for await _ in center.notifications(named: name) {
                    await self?.coordinator.recoverTeamScopeIfNeeded()
                }
            })
        }
        let (pathSatisfied, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pathMonitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.cmux.auth.team-scope-path"))
        tasks.append(Task { @MainActor [weak self] in
            var wasSatisfied = false
            for await satisfied in pathSatisfied {
                defer { wasSatisfied = satisfied }
                guard satisfied, !wasSatisfied else { continue }
                await self?.coordinator.recoverTeamScopeIfNeeded()
            }
        })
    }
}

/// Native confirmation shown before a stateless auth callback that cmux did
/// not request (for example a `cmux://auth-callback` link opened by a web
/// page) may sign the app in. Declining is the default action.
@MainActor
enum UnsolicitedAuthCallbackApprovalPrompt {
    static func present(_ request: UnsolicitedAuthCallbackApprovalRequest) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = request.replacesSignedInSession ? .critical : .warning
        alert.messageText = title(for: request)
        alert.informativeText = message(for: request)
        // The first button is the default (Return) action, so declining is the
        // path of least resistance.
        alert.addButton(withTitle: String(
            localized: "account.callbackApproval.cancel",
            defaultValue: "Don\u{2019}t Sign In"
        ))
        alert.addButton(withTitle: request.replacesSignedInSession
            ? String(localized: "account.callbackApproval.replace.confirm", defaultValue: "Switch Account")
            : String(localized: "account.callbackApproval.confirm", defaultValue: "Sign In"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func title(for request: UnsolicitedAuthCallbackApprovalRequest) -> String {
        if request.replacesSignedInSession {
            return String(
                localized: "account.callbackApproval.replace.title",
                defaultValue: "Switch cmux to another account?"
            )
        }
        return String(
            localized: "account.callbackApproval.title",
            defaultValue: "Sign in to cmux from a link?"
        )
    }

    private static func message(for request: UnsolicitedAuthCallbackApprovalRequest) -> String {
        let account = String(
            localized: "account.callbackApproval.message.unknown",
            defaultValue: "A link is asking cmux to sign in to an account. Continue only if you just signed in to cmux in your browser."
        )
        guard request.replacesSignedInSession else { return account }
        let warning = String(
            localized: "account.callbackApproval.replace.generic",
            defaultValue: "You\u{2019}re already signed in. Continuing replaces that session, and new cmux activity will belong to the account in the link. If you didn\u{2019}t just choose this account yourself, click Don\u{2019}t Sign In."
        )
        return "\(account)\n\n\(warning)"
    }
}

/// This build's tunnels, captured when sign-out begins and revoked by the
/// sign-out tail.
@MainActor
private final class SignOutTunnelRoles {
    /// Nil until sign-out begins; an empty capture means this build had no
    /// tunnel, and must not be refilled from disk after teardown.
    var roles: [CloudTunnelRole]?

    /// The captured roles, or the ones still on disk when sign-out began on a
    /// path that did not capture them. Clears the capture.
    func take() -> [CloudTunnelRole] {
        defer { roles = nil }
        return roles ?? VMTunnelManager.storedRoles()
    }
}
