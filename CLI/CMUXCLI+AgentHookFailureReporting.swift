import CmuxFoundation
import Foundation
import OSLog

nonisolated private let agentHookDeliveryLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "AgentHookDelivery"
)

extension CMUXCLI {
    /// Chooses the live wrapper PID for Codex while preserving legacy precedence for other agents.
    func preferredAgentHookEventPID(
        agentName: String,
        mappedPID: Int?,
        inferredPID: Int?
    ) -> Int? {
        agentName == "codex"
            ? inferredPID ?? mappedPID
            : mappedPID ?? inferredPID
    }

    /// Reports a persistently throttled hook failure without serializing raw transport details.
    ///
    /// `failureKind` overrides the reported `underlying_error_type` with a
    /// stable, privacy-safe kind; otherwise it is the error's type, or
    /// `unresolved-target` when neither is given.
    func reportAgentHookFailure(
        stage: AgentHookFailureStage,
        agentName: String,
        sessionId: String,
        event: String,
        error: Error? = nil,
        failureKind: String? = nil,
        store: ClaudeHookSessionStore,
        classificationContext: AgentHookFailureClassificationContext,
        deadline: Date? = nil
    ) {
        let shortSessionId = String(sessionId.prefix(12))
        let errorType = failureKind
            ?? error.map { String(reflecting: type(of: $0)) }
            ?? "unresolved-target"
        let failureDescription: String
        switch stage {
        case .targetResolution:
            failureDescription = String.localizedStringWithFormat(
                String(
                    localized: "cli.agentHook.error.targetResolution",
                    defaultValue: "Agent hook target resolution failed for %@ %@."
                ),
                agentName,
                event
            )
        case .notificationDelivery:
            failureDescription = String.localizedStringWithFormat(
                String(
                    localized: "cli.agentHook.error.notificationDelivery",
                    defaultValue: "Agent hook notification delivery failed for %@ %@."
                ),
                agentName,
                event
            )
        case .journalAppend:
            failureDescription = String.localizedStringWithFormat(
                String(
                    localized: "cli.agentHook.error.journalAppend",
                    defaultValue: "Agent hook journal append failed for %@ %@."
                ),
                agentName,
                event
            )
        }
        let userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: failureDescription,
            NSDebugDescriptionErrorKey: failureDescription,
            "underlying_error_type": errorType,
        ]
        let reportableError = NSError(
            domain: "com.cmuxterm.cli.agent-hook.\(stage.rawValue)",
            code: 1,
            userInfo: userInfo
        )
        let telemetryStage = "agent-hook-\(stage.rawValue)"
        let telemetryData: [String: Any] = [
            "agent": agentName,
            "hook_event": event,
            "has_session_id": !sessionId.isEmpty,
            "underlying_error_type": errorType,
            "failure_description": failureDescription,
        ]
        // Classify before claiming the durable slot. Expected lifecycle noise
        // must not suppress a later actionable failure for the same session.
        guard !isExpectedAgentHookFailure(
            stage: telemetryStage,
            error: reportableError,
            data: telemetryData,
            classificationError: error,
            context: classificationContext
        ) else {
            return
        }
        guard (try? store.claimAgentHookFailureReport(
            agentName: agentName,
            stage: stage.rawValue,
            sessionId: sessionId,
            deadline: deadline
        )) == true else {
            return
        }
        agentHookDeliveryLogger.error(
            "Agent hook failed stage=\(stage.rawValue, privacy: .public) event=\(event, privacy: .public) agent=\(agentName, privacy: .public) session=\(shortSessionId, privacy: .private(mask: .hash)) errorType=\(errorType, privacy: .private(mask: .hash)) description=\(failureDescription, privacy: .public)"
        )
    }

    /// Preserves original provenance and eligibility before claiming a local log slot.
    private func isExpectedAgentHookFailure(
        stage: String,
        error: Error,
        data: [String: Any],
        classificationError: Error?,
        context: AgentHookFailureClassificationContext
    ) -> Bool {
        guard context.filtersExpectedFailures else { return false }
        let noiseFilter = SentryNoiseFilter()
        let errorDescription = String(describing: error)
        let classificationCandidate = classificationError ?? error
        let cliErrorMetadata = agentHookCLIErrorMetadata(for: classificationCandidate)
        let classificationMessage = cliErrorMetadata.legacyMessage
            ?? String(describing: classificationCandidate)
        let dataKeys = Set(data.keys)
        let isAgentHookStage = stage.hasPrefix("agent-hook-")
        let hasStructuredCLIErrorCode = cliErrorMetadata.code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let isExpectedAgentHookCLIError =
            isAgentHookStage &&
            (noiseFilter.isExpectedCLIAppLifecycleError(
                code: cliErrorMetadata.code,
                message: classificationMessage
            ) ||
                cliErrorMetadata.socketPathMissing)
        let isExpectedLegacyCLIError: Bool
        if !hasStructuredCLIErrorCode {
            isExpectedLegacyCLIError =
                noiseFilter.isExpectedCLISocketTransportFailure(
                    stage: stage,
                    message: classificationMessage,
                    dataKeys: dataKeys,
                    allowSandboxPolicyDenial: context.allowsSandboxPolicyDenial
                ) ||
                (isAgentHookStage &&
                    noiseFilter.isExpectedLegacyCLIAppLifecycleMessage(classificationMessage))
        } else {
            isExpectedLegacyCLIError = false
        }
        let isExpectedTransportFailure = noiseFilter.isExpectedCLISocketTransportFailure(
            stage: stage,
            message: errorDescription,
            dataKeys: dataKeys,
            allowSandboxPolicyDenial: context.allowsSandboxPolicyDenial,
            cliErrorCode: cliErrorMetadata.code,
            socketPathMissing: cliErrorMetadata.socketPathMissing
        )
        let isExpectedProtocolOutcome =
            cliErrorMetadata.isStructuredProtocolResponse &&
            noiseFilter.isExpectedCLIProtocolOutcomeCode(cliErrorMetadata.code)
        return isExpectedAgentHookCLIError ||
                isExpectedLegacyCLIError ||
                isExpectedTransportFailure ||
                isExpectedProtocolOutcome
    }

    private func agentHookCLIErrorMetadata(for error: Error) -> (code: String?, socketPathMissing: Bool, legacyMessage: String?, isStructuredProtocolResponse: Bool) {
        if let cliError = error as? CLIError {
            return (
                code: cliError.v2Code,
                socketPathMissing: cliError.socketFailureKind == .pathMissing,
                legacyMessage: String(describing: cliError),
                isStructuredProtocolResponse: cliError.isStructuredProtocolResponse
            )
        }

        // A few command helpers wrap failures in NSError. Walk the standard
        // underlying-error chain so the same policy applies after wrapping,
        // while keeping a hard bound against malformed cycles.
        var current: NSError? = error as NSError
        var remaining = 8
        while let candidate = current, remaining > 0 {
            if let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? CLIError {
                return (
                    code: underlying.v2Code,
                    socketPathMissing: underlying.socketFailureKind == .pathMissing,
                    legacyMessage: String(describing: underlying),
                    isStructuredProtocolResponse: underlying.isStructuredProtocolResponse
                )
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            remaining -= 1
        }
        return (
            code: nil,
            socketPathMissing: false,
            legacyMessage: nil,
            isStructuredProtocolResponse: false
        )
    }
}
