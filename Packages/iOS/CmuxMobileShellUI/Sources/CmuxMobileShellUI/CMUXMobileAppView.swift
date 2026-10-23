import CmuxMobileShell
import SwiftUI
#if os(iOS)
import CmuxMobileShellModel
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore
    /// App-lifetime owner for the initial explicit-attach versus saved-Mac
    /// reconnect decision. Root view lifecycle callbacks share this instance.
    @State private var startupConnectionCoordinator = MobileStartupConnectionCoordinator()
    private let signOutHook: MobileSignOutHook
    #if os(iOS)
    private let onboardingStore: MobileOnboardingStore
    #endif

    #if os(iOS)
    /// Creates the app view.
    /// - Parameters:
    ///   - store: The shell store backing the workspace UI.
    ///   - onboardingStore: The first-run onboarding progress store. Defaults to
    ///     a `.standard`-backed store forced complete, so SwiftUI previews and
    ///     ad-hoc construction never present onboarding.
    ///   - signOutHook: The action invoked when the mobile shell signs out.
    public init(
        store: CMUXMobileShellStore = .preview(),
        onboardingStore: MobileOnboardingStore = MobileOnboardingStore(defaults: .standard, forceComplete: true),
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        _store = State(initialValue: store)
        self.onboardingStore = onboardingStore
        self.signOutHook = signOutHook
    }
    #else
    /// Creates the app view on non-iOS platforms.
    /// - Parameters:
    ///   - store: The shell store backing the workspace UI.
    ///   - signOutHook: The action invoked when the mobile shell signs out.
    public init(
        store: CMUXMobileShellStore = .preview(),
        signOutHook: MobileSignOutHook = MobileSignOutHook()
    ) {
        _store = State(initialValue: store)
        self.signOutHook = signOutHook
    }
    #endif

    /// Renders the platform root view.
    public var body: some View {
        #if os(iOS)
        CMUXMobileRootView(
            store: store,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook,
            startupConnectionCoordinator: startupConnectionCoordinator
        )
        #else
        CMUXMobileRootView(
            store: store,
            signOutHook: signOutHook,
            startupConnectionCoordinator: startupConnectionCoordinator
        )
        #endif
    }
}
