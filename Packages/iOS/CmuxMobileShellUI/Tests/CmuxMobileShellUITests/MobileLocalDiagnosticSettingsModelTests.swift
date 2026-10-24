import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileLocalDiagnosticSettingsModelTests {
    @Test(arguments: [false, true])
    func initializationDoesNotWriteOrClearLogs(_ initial: Bool) async throws {
        let log = DiagnosticLog(capacity: 4)
        log.recordAppEvent(.settingsOpened)
        try await waitForEvents(log, count: 1)
        var calls: [Bool] = []
        let model = MobileLocalDiagnosticSettingsModel(
            verboseLogEnabled: initial, diagnosticLog: log,
            setFileLogging: { enabled in calls.append(enabled); return true }
        )
        #expect(model.verboseLogEnabled == initial)
        #expect(calls.isEmpty)
        #expect(await log.processedCount() == 1)
        #expect(await log.snapshot().events.first?.a == DiagnosticAppEventKind.settingsOpened.rawValue)
    }

    @Test(arguments: [false, true])
    func acceptedToggleRecordsRealResult(_ enabled: Bool) async throws {
        let log = DiagnosticLog(capacity: 4)
        var calls: [Bool] = []
        let model = MobileLocalDiagnosticSettingsModel(
            verboseLogEnabled: !enabled, diagnosticLog: log,
            setFileLogging: { requested in calls.append(requested); return true }
        )
        await model.setVerboseLog(enabled)
        try await waitForEvents(log, count: 1)
        #expect(calls == [enabled])
        #expect(model.verboseLogEnabled == enabled)
        let event = try #require(await log.snapshot().events.last)
        #expect(event.a == DiagnosticAppEventKind.verboseDiagnosticLoggingChanged.rawValue)
        #expect(event.b == nil)
        #expect(event.c == (enabled ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func deniedToggleRollsBackAndRecordsPermissionDenied(_ enabled: Bool) async throws {
        let log = DiagnosticLog(capacity: 4)
        var calls: [Bool] = []
        let model = MobileLocalDiagnosticSettingsModel(
            verboseLogEnabled: !enabled, diagnosticLog: log,
            setFileLogging: { requested in calls.append(requested); return false }
        )
        await model.setVerboseLog(enabled)
        try await waitForEvents(log, count: 1)
        #expect(calls == [enabled])
        #expect(!model.verboseLogEnabled)
        let event = try #require(await log.snapshot().events.last)
        #expect(event.a == DiagnosticAppEventKind.verboseDiagnosticLoggingChanged.rawValue)
        #expect(event.b == DiagnosticFailureKind.permissionDenied.rawValue)
        #expect(event.c == 0)
    }

    @Test func optionalDiagnosticLogDoesNotPreventInjectedLoggerOperation() async {
        var calls: [Bool] = []
        let model = MobileLocalDiagnosticSettingsModel(
            verboseLogEnabled: false,
            setFileLogging: { enabled in calls.append(enabled); return true }
        )
        await model.setVerboseLog(true)
        #expect(calls == [true])
        #expect(model.verboseLogEnabled)
    }

    @Test func updatesUIBeforeAwaitingLoggerAndUsesItsDenial() async throws {
        var pending: CheckedContinuation<Bool, Never>?
        let model = MobileLocalDiagnosticSettingsModel(
            verboseLogEnabled: false,
            setFileLogging: { _ in await withCheckedContinuation { pending = $0 } }
        )
        let operation = Task { await model.setVerboseLog(true) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while pending == nil, clock.now < deadline { await Task.yield() }
        let continuation = try #require(pending)
        #expect(model.verboseLogEnabled)
        continuation.resume(returning: false)
        await operation.value
        #expect(!model.verboseLogEnabled)
    }

    private func waitForEvents(_ log: DiagnosticLog, count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await log.processedCount() < count, clock.now < deadline { await Task.yield() }
        #expect(await log.processedCount() == count)
    }
}
