import CMUXMobileCore
import Observation

/// Local diagnostic preferences, independent of networking settings controllers.
@MainActor
@Observable
final class MobileLocalDiagnosticSettingsModel {
    private(set) var verboseLogEnabled: Bool
    private let diagnosticLog: DiagnosticLog?
    private let setFileLogging: @MainActor (Bool) async -> Bool

    init(
        verboseLogEnabled: Bool,
        diagnosticLog: DiagnosticLog? = nil,
        setFileLogging: @escaping @MainActor (Bool) async -> Bool
    ) {
        self.verboseLogEnabled = verboseLogEnabled
        self.diagnosticLog = diagnosticLog
        self.setFileLogging = setFileLogging
    }

    func setVerboseLog(_ enabled: Bool) async {
        verboseLogEnabled = enabled
        let accepted = await setFileLogging(enabled)
        if !accepted {
            verboseLogEnabled = false
        }
        diagnosticLog?.recordAppEvent(
            .verboseDiagnosticLoggingChanged,
            failure: accepted ? nil : .permissionDenied,
            count: verboseLogEnabled ? 1 : 0
        )
    }
}
