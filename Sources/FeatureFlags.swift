import CmuxSettings
import Foundation
import Observation
import os

/// Local runtime feature flags for the macOS app.
/// A permitted explicit local override takes priority over the per-flag default.
/// Historical remote snapshots and release-control identities are neither read
/// nor modified. Local mutations publish observable resolutions and the shared
/// off-main snapshot; no remote provider, fetch or refresh timer is installed.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags(publishesOffMainSnapshot: true)

    private static let mobileConnectButtonDefault = false
    private static let sidebarAccountButtonDefault = true

    private static let agentChatUIDefault = false
    #if DEBUG
    private nonisolated static let mobileWorkspaceChangesDefault = true
    #else
    private nonisolated static let mobileWorkspaceChangesDefault = false
    #endif
    private static let sidebarWorkspaceAgentSpinnerDefault = false
    private static let computerUseUXDefault = true
    private nonisolated static let simulatorDefault = true
    private static let workspaceTodoControlsDefault = false
    private static let appKitSidebarListDefault = true
    private static let mobileTerminalFilesChipDefault = true
    private nonisolated static let mobileTaskComposerDefault = true
    private static let goPlanDefault = false
    private static let agentInboxQuickViewDefault = false
    nonisolated static let cloudMachinesDefault = true
    private nonisolated static let conversationSidebarDefault = false

    private static let overrideKeyPrefix = "cmux.flags.override."
    // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: true)
    // Renders the workspace sidebar with the AppKit NSTableView list
    // (virtualized rows, measured-once heights) instead of the SwiftUI
    // LazyVStack. On by default after the remote rollout reached 100%.
    static let appKitSidebarListFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-appkit-list-experiment",
        title: String(
            localized: "featureFlags.appKitSidebarList.title",
            defaultValue: "Lawrence Sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.appKitSidebarList.description",
            defaultValue: "Renders the workspace sidebar with a native AppKit list and divider for smoother scrolling and resizing with many workspaces."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.appKitSidebarListDefault
    )

    // FLAG(key: mobile-workspace-changes-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-01-19, defaultWhenUnavailable: false)
    // Serves the iOS diff viewer: advertises workspace.changes.v1 to phones
    // and answers the mobile.workspace.changes.* RPCs behind it. Every iOS
    // entry point (workspace-row chip, toolbar button, one-time hint, Changes
    // sheet, summary polling) feature-detects on that capability, so this one
    // Mac-side flag turns the whole feature off end to end. Release builds
    // keep it off until the PostHog flag enables it; DEBUG keeps it on for
    // dogfood.
    nonisolated static let mobileWorkspaceChangesFlag = CmuxFeatureFlagDefinition(
        key: "mobile-workspace-changes-enabled-release",
        title: String(
            localized: "featureFlags.mobileWorkspaceChanges.title",
            defaultValue: "Mobile diff viewer"
        ),
        flagDescription: String(
            localized: "featureFlags.mobileWorkspaceChanges.description",
            defaultValue: "Serves workspace diffs to paired phones: the iOS changes chip, toolbar button, and Changes sheet."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileWorkspaceChangesDefault
    )

    // FLAG(key: ios-artifact-chip-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-01, defaultWhenUnavailable: true)
    // Controls the fully integrated terminal Files chip on iOS. The enabled
    // fallback preserves the shipping behavior when PostHog is unavailable;
    // a remote false value is the emergency kill switch.
    static let mobileTerminalFilesChipFlag = CmuxFeatureFlagDefinition(
        key: "ios-artifact-chip-enabled-release",
        title: String(
            localized: "featureFlags.mobileTerminalFilesChip.title",
            defaultValue: "Mobile terminal Files chip"
        ),
        flagDescription: String(
            localized: "featureFlags.mobileTerminalFilesChip.description",
            defaultValue: "Shows the Files chip over iOS terminals and runs its visible-path count scan."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileTerminalFilesChipDefault
    )

    // FLAG(key: simulator-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-16, defaultWhenUnavailable: true)
    // Controls every Simulator entrypoint and active pane. The enabled
    // fallback preserves access when PostHog is unavailable, while the
    // remote value provides a release kill switch. Declared nonisolated so
    // the mobile host's off-main capability list can gate the advertised
    // simulator capabilities on the same flag as RPC dispatch.
    nonisolated static let simulatorFlag = CmuxFeatureFlagDefinition(
        key: "simulator-enabled-release",
        title: String(
            localized: "featureFlags.simulator.title",
            defaultValue: "Simulator"
        ),
        flagDescription: String(
            localized: "featureFlags.simulator.description",
            defaultValue: "Enables iPhone and iPad Simulator panes, commands, and automation."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.simulatorDefault
    )

    // FLAG(key: mobile-task-composer-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-12-15, defaultWhenUnavailable: true)
    // Controls the iOS Task Composer from the Mac host. When off, the Mac stops
    // advertising task-create/model/directory/attachment capabilities and
    // task-specific RPCs fail with capability_disabled, so paired phones hide
    // the composer without needing a user-visible Beta toggle.
    nonisolated static let mobileTaskComposerFlag = CmuxFeatureFlagDefinition(
        key: "mobile-task-composer-enabled-release",
        title: String(
            localized: "featureFlags.mobileTaskComposer.title",
            defaultValue: "Mobile Task Composer"
        ),
        flagDescription: String(
            localized: "featureFlags.mobileTaskComposer.description",
            defaultValue: "Enables the iOS New Task composer, including task model discovery, directory picking, and attachment staging."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileTaskComposerDefault
    )

    // FLAG(key: go-plan-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-12-01, defaultWhenUnavailable: false)
    // Controls the $10/month Go plan rollout. Keep this off until capacity and
    // support are ready; existing Go subscribers keep their entitlements.
    static let goPlanFlag = CmuxFeatureFlagDefinition(
        key: "go-plan-enabled-release",
        title: String(localized: "featureFlags.goPlan.title", defaultValue: "Go plan"),
        flagDescription: String(
            localized: "featureFlags.goPlan.description",
            defaultValue: "Shows and sells the $10/month Go personal Cloud VM plan."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.goPlanDefault
    )

    // FLAG(key: agent-inbox-quick-view-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: false)
    // Keeps the agent inbox quick view behind an explicit rollout while the
    // placement and cross-agent attention model are evaluated.
    static let agentInboxQuickViewFlag = CmuxFeatureFlagDefinition(
        key: "agent-inbox-quick-view-enabled-release",
        title: String(localized: "featureFlags.agentInbox.title", defaultValue: "Agent Inbox quick view"),
        flagDescription: String(localized: "featureFlags.agentInbox.description", defaultValue: "Shows a keyboard-summoned inbox for agent messages, pending Feed decisions, and finished turns."),
        defaultWhenUnavailable: CmuxFeatureFlags.agentInboxQuickViewDefault
    )

    // FLAG(key: conversation-sidebar-release, owner: teamleaderleo,
    //      reviewBy: 2026-12-01, defaultWhenUnavailable: false)
    // Controls availability of the opt-in multi-provider conversation sidebar.
    // The user-facing beta setting is evaluated separately by the sidebar
    // integration; this flag is the remote rollout gate and emergency kill
    // switch for the feature.
    nonisolated static let conversationSidebarFlag = CmuxFeatureFlagDefinition(
        key: "conversation-sidebar-release",
        title: String(
            localized: "featureFlags.conversationSidebar.title",
            defaultValue: "Multi-provider conversation sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.conversationSidebar.description",
            defaultValue: "Enables the opt-in sidebar for conversations from multiple coding-agent providers."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.conversationSidebarDefault
    )

    // FLAG(key: mac-account-directory-release, owner: lawrencecchen,
    //      reviewBy: 2027-01-31, defaultWhenUnavailable: true)
    // Lets My Devices find and admit the same user's Macs across teams through
    // the per-user account directory. Off falls back to team-only discovery
    // and admission; the enabled fallback keeps the shipping behavior when
    // PostHog is unavailable, and a remote false value is the kill switch.
    nonisolated static let macAccountDirectoryFlag = CmuxFeatureFlagDefinition(
        key: "mac-account-directory-release",
        title: String(
            localized: "featureFlags.macAccountDirectory.title",
            defaultValue: "Cross-team My Devices"
        ),
        flagDescription: String(
            localized: "featureFlags.macAccountDirectory.description",
            defaultValue: "Finds and connects your Macs signed in to the same account even when they selected different teams."
        ),
        defaultWhenUnavailable: true
    )

    // FLAG(key: window-hints-release, owner: teamleaderleo,
    //      reviewBy: 2027-01-31, defaultWhenUnavailable: false)
    // Hint mode (Show Hints, Cmd-J): labels every clickable control in the
    // window so typing a label clicks it. Off until the labels are styled;
    // a local debug override turns it on for testing.
    nonisolated static let windowHintsFlag = CmuxFeatureFlagDefinition(
        key: "window-hints-release",
        title: String(localized: "featureFlags.windowHints.title", defaultValue: "Click by Hint"),
        flagDescription: String(
            localized: "featureFlags.windowHints.description",
            defaultValue: "Labels every clickable control in the window so typing a label clicks it."
        ),
        defaultWhenUnavailable: false
    )

    // FLAG(key: mobile-connect-button-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-12-15, defaultWhenUnavailable: false)
    // Shows the bottom-left sidebar iPhone button that opens the Tailscale
    // Pairing workspace. It stays hidden until the remote flag or a
    // local debug override enables it.
    static let mobileConnectButtonFlag = CmuxFeatureFlagDefinition(
        key: "mobile-connect-button-enabled-release",
        title: String(localized: "featureFlags.mobileConnect.title", defaultValue: "Mobile Pairing button"),
        flagDescription: String(
            localized: "featureFlags.mobileConnect.description",
            defaultValue: "Shows the Mobile Pairing button in the sidebar footer."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.mobileConnectButtonDefault
    )

    // FLAG(key: sidebar-account-button-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-16, defaultWhenUnavailable: true)
    // Shows the account control in the bottom-left sidebar footer. The
    // Settings account section remains available when this shortcut is off.
    static let sidebarAccountButtonFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-account-button-enabled-release",
        title: String(localized: "featureFlags.sidebarAccount.title", defaultValue: "Sidebar account button"),
        flagDescription: String(
            localized: "featureFlags.sidebarAccount.description",
            defaultValue: "Shows the profile and sign-in control in the sidebar footer."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.sidebarAccountButtonDefault
    )

    // FLAG(key: agent-chat-ui-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: false)
    // Shows the Agent Chat entrypoints: the new-workspace dropdown item,
    // command-palette command, surface-tab-bar button, and shared action
    // executor. Hidden by default until the sidecar UX is ready to ship.
    static let agentChatUIFlag = CmuxFeatureFlagDefinition(
        key: "agent-chat-ui-enabled-release",
        title: String(localized: "featureFlags.agentChat.title", defaultValue: "Agent Chat UI"),
        flagDescription: String(
            localized: "featureFlags.agentChat.description",
            defaultValue: "Shows Agent Chat entrypoints in the new-workspace dropdown, command palette, and surface tab bar."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.agentChatUIDefault
    )

    // FLAG(key: sidebar-workspace-agent-spinner-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: false)
    // Shows the coding-agent activity spinner in workspace rows. Hidden
    // by default while multi-agent lifecycle edge cases are investigated.
    static let sidebarWorkspaceAgentSpinnerFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-workspace-agent-spinner-experiment",
        title: String(
            localized: "featureFlags.sidebarWorkspaceAgentSpinner.title",
            defaultValue: "Workspace agent spinner"
        ),
        flagDescription: String(
            localized: "featureFlags.sidebarWorkspaceAgentSpinner.description",
            defaultValue: "Shows a spinner in workspace rows while coding agents are running."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerDefault
    )

    // FLAG(key: computer-use-ux-enabled-release, owner: austinwang,
    //      reviewBy: 2027-01-19, defaultWhenUnavailable: true)
    // Shows the computer-use status item and allows automatic onboarding.
    // The settings and terminal kill switch remain available if this UI
    // flag is remotely disabled.
    static let computerUseUXFlag = CmuxFeatureFlagDefinition(
        key: "computer-use-ux-enabled-release",
        title: String(localized: "featureFlags.computerUseUX.title", defaultValue: "cmux Computer Use UX"),
        flagDescription: String(
            localized: "featureFlags.computerUseUX.description",
            defaultValue: "Shows the Computer Use menu-bar item and automatic onboarding."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.computerUseUXDefault
    )

    // FLAG(key: workspace-todo-controls-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-02-16, defaultWhenUnavailable: false)
    // Shows user-facing workspace todo controls that create checklist
    // items or set completion/status lanes. Hidden until the local
    // beta setting opts in or the PostHog flag is enabled.
    static let workspaceTodoControlsFlag = CmuxFeatureFlagDefinition(
        key: "workspace-todo-controls-enabled-release",
        title: String(
            localized: "featureFlags.workspaceTodoControls.title",
            defaultValue: "Workspace todo controls"
        ),
        flagDescription: String(
            localized: "featureFlags.workspaceTodoControls.description",
            defaultValue: "Shows Add Checklist Item and workspace completion status controls."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.workspaceTodoControlsDefault
    )

    // Registry order is used by the inspector; accessors bind to named definitions.
    static let allFlags: [CmuxFeatureFlagDefinition] = {
        [
            CmuxFeatureFlags.mobileConnectButtonFlag,
            CmuxFeatureFlags.sidebarAccountButtonFlag,
            CmuxFeatureFlags.agentChatUIFlag,
            CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerFlag,
            CmuxFeatureFlags.computerUseUXFlag,
            CmuxFeatureFlags.simulatorFlag,
            CmuxFeatureFlags.workspaceTodoControlsFlag,
            CmuxFeatureFlags.appKitSidebarListFlag,
            CmuxFeatureFlags.mobileWorkspaceChangesFlag,
            CmuxFeatureFlags.mobileTerminalFilesChipFlag,
            CmuxFeatureFlags.mobileTaskComposerFlag,
            CmuxFeatureFlags.goPlanFlag,
            CmuxFeatureFlags.agentInboxQuickViewFlag,
            CmuxFeatureFlags.conversationSidebarFlag,
            CmuxFeatureFlags.macAccountDirectoryFlag,
            CmuxFeatureFlags.windowHintsFlag
        ]
    }()

    var isMobileConnectButtonEnabled: Bool {
        effectiveValue(for: Self.mobileConnectButtonFlag)
    }

    var isAgentChatUIEnabled: Bool {
        effectiveValue(for: Self.agentChatUIFlag)
    }

    var isSidebarAccountButtonEnabled: Bool {
        effectiveValue(for: Self.sidebarAccountButtonFlag)
    }

    var isSidebarWorkspaceAgentSpinnerEnabled: Bool {
        effectiveValue(for: Self.sidebarWorkspaceAgentSpinnerFlag)
    }

    var isComputerUseUXEnabled: Bool {
        effectiveValue(for: Self.computerUseUXFlag)
    }
    var isSimulatorEnabled: Bool {
        effectiveValue(for: Self.simulatorFlag)
    }
    var isWorkspaceTodoControlsEnabled: Bool {
        effectiveValue(for: Self.workspaceTodoControlsFlag)
    }
    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.appKitSidebarListFlag)
    }

    var isMobileWorkspaceChangesEnabled: Bool {
        effectiveValue(for: Self.mobileWorkspaceChangesFlag)
    }

    var isMobileTerminalFilesChipEnabled: Bool {
        effectiveValue(for: Self.mobileTerminalFilesChipFlag)
    }

    var isMobileTaskComposerEnabled: Bool {
        effectiveValue(for: Self.mobileTaskComposerFlag)
    }

    var isGoPlanEnabled: Bool {
        effectiveValue(for: Self.goPlanFlag)
    }

    var isAgentInboxQuickViewEnabled: Bool {
        effectiveValue(for: Self.agentInboxQuickViewFlag)
    }

    var isWindowHintsEnabled: Bool {
        effectiveValue(for: Self.windowHintsFlag) || ClickByHintPreview.isOptedIn()
    }

    var isConversationSidebarAvailable: Bool {
        effectiveValue(for: Self.conversationSidebarFlag)
    }

    /// Effective values mirrored for nonisolated readers: the mobile host
    /// serves status payloads (which carry the capability list) off the main
    /// actor. Written only by the shared instance so test instances cannot
    /// stomp process-wide state. Before the shared instance exists, readers
    /// get the per-flag compile-time default (fail-closed for release flags).
    private nonisolated static let offMainEffectiveValues = OSAllocatedUnfairLock(
        initialState: [String: Bool]()
    )

    nonisolated static func offMainEffectiveValue(
        for definition: CmuxFeatureFlagDefinition
    ) -> Bool {
        offMainEffectiveValues.withLock { $0[definition.key] }
            ?? definition.defaultWhenUnavailable
    }

    @ObservationIgnored
    private let publishesOffMainSnapshot: Bool
    @ObservationIgnored
    private let overrideCapability: CmuxFeatureFlagOverrideCapability
    @ObservationIgnored
    private let defaults: UserDefaults
    private var localOverridesByKey: [String: Bool] = [:]
    private var resolutionsByKey: [String: CmuxFeatureFlagResolution] = [:]

    init(
        defaults: UserDefaults = .standard,
        overrideCapability: CmuxFeatureFlagOverrideCapability = .init(),
        publishesOffMainSnapshot: Bool = false
    ) {
        self.defaults = defaults
        self.overrideCapability = overrideCapability
        self.publishesOffMainSnapshot = publishesOffMainSnapshot
        // Cloud's local value is now a first-use activation marker, so it must
        // survive tagged debug artifact reloads just like any other persisted
        // product state. The explicit dogfood marker may still opt a fresh
        // debug artifact in; only the temporary remote override is reset when
        // a tagged artifact is reopened.
        if overrideCapability.enablesCloudDogfood {
            defaults.set(true, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)
            defaults.set(true, forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
        } else if overrideCapability.isTaggedDebugArtifact {
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
            if overrideCapability.hasCloudDogfoodMarker {
                defaults.set(false, forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
            }
        }
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        // Cloud is retired from remote delivery but tagged debug artifacts
        // still use its persisted local override as a compatibility control.
        if let value = Self.storedOverrideValue(for: Self.cloudMachinesFlag.key, defaults: defaults) {
            localOverridesByKey[Self.cloudMachinesFlag.key] = value
        }
        recomputeEffectiveValues()
    }

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        resolution(for: definition).effectiveValue
    }

    func resolution(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagResolution {
        resolutionsByKey[definition.key] ?? CmuxFeatureFlagResolution(
            overrideValue: localOverridesByKey[definition.key],
            defaultValue: definition.defaultWhenUnavailable,
            overridePolicy: overrideCapability.policy(for: definition)
        )
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        guard value == nil || resolution(for: definition).allowsLocalOverride else { return }

        let previousResolutions = resolutionsByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func clearAllOverrides() {
        let previousResolutions = resolutionsByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        if localOverridesByKey.removeValue(forKey: Self.cloudMachinesFlag.key) != nil {
            clearedAnyOverride = true
        }
        defaults.removeObject(forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    private func recomputeEffectiveValues() {
        resolutionsByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = CmuxFeatureFlagResolution(
                overrideValue: localOverridesByKey[definition.key],
                defaultValue: definition.defaultWhenUnavailable,
                overridePolicy: overrideCapability.policy(for: definition)
            )
        }
        if publishesOffMainSnapshot {
            let effectiveValues = resolutionsByKey.mapValues(\.effectiveValue)
            Self.offMainEffectiveValues.withLock { $0 = effectiveValues }
        }
    }

    private func postChangeIfNeeded(previousResolutions: [String: CmuxFeatureFlagResolution]) {
        if previousResolutions != resolutionsByKey {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        storedBoolValue(forKey: overrideDefaultsKey(for: key), defaults: defaults)
    }

    private static func storedBoolValue(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }


}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
