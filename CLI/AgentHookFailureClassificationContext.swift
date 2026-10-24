import CmuxFoundation
import CmuxSettings
import Foundation

/// Captures legacy local diagnostic filtering eligibility once at command entry.
/// No reporting is performed; old environment names remain compatibility inputs.
struct AgentHookFailureClassificationContext: Sendable {
    let filtersExpectedFailures: Bool
    let allowsSandboxPolicyDenial: Bool

    init(command: String, commandArgs: [String], processEnv: [String: String]) {
        let disabledByEnv =
            processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||
            processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1" ||
            (command.lowercased() == "hooks" &&
                (commandArgs.first?.lowercased() ?? "help") == "enqueue")
        let buildIdentityPolicy = SentryBuildIdentityPolicy(
            bundleIdentifier: Self.currentSentryBundleIdentifier(environment: processEnv),
            trustedBaseBundleIdentifier: SocketPathMarkerFiles.stableBundleIdentifier
        )
        filtersExpectedFailures = !disabledByEnv && buildIdentityPolicy.allowsTelemetry
        allowsSandboxPolicyDenial = CLISocketSentryPolicy(environment: processEnv).allowsSandboxPolicyDenial
    }

    private static func currentSentryBundleIdentifier(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let bundleIdentifier = environment["CMUX_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = currentSentryBundle()?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private static func currentSentryBundle() -> Bundle? {
        if Bundle.main.bundleIdentifier?.isEmpty == false {
            return Bundle.main
        }

        if let bundle = CLIExecutableLocator.enclosingAppBundle() {
            return bundle
        }

        return Bundle.main
    }
}
