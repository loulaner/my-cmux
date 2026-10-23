import Foundation
import CmuxMobileTransport
import CmuxMobileRPC
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectClientControllerTests {
    #if DEBUG
    @Test func diagnosticsExcludeServerMessagesAndUnknownCodes() {
        let secret = "credential-and-terminal-content-must-not-leak"
        #expect(MobileLocalDirectFailureDiagnostic(MobileShellConnectionError.rpcError(secret, secret)).kind == "rpc_other")
        #expect(MobileLocalDirectFailureDiagnostic(MobileShellConnectionError.rpcError("detached", secret)).kind == "rpc_detached")
        #expect(MobileLocalDirectFailureDiagnostic(MobileShellConnectionError.requestTimedOut).kind == "request_timeout")
        #expect(MobileLocalDirectFailureDiagnostic(CmxLocalDirectConnector.Failure.vpnUnavailable).kind == "vpn_unavailable")
        #expect(MobileLocalDirectFailureDiagnostic(CmxLocalDirectAdmission.Failure.timedOut).kind == "admission_timeout")
        #expect(MobileLocalDirectFailureDiagnostic(CancellationError()).kind == "cancelled")
    }
    #endif
    private func controller(_ fixture: MobileDirectClientFixture) -> MobileLocalDirectClientController {
        .init(store: fixture, connect: { _, _ in try await fixture.open() }, admit: { _, _ in try await fixture.admit() })
    }
    private func saved() throws -> MobileLocalDirectClientRecord {
        try .init(host: "100.70.1.2", port: 49443, hostID: MobileDirectClientFixture.hostID,
            deviceID: MobileDirectClientFixture.deviceID, token: Data(repeating: 42, count: 32))
    }
    private func wait(_ client: MobileLocalDirectClientController, for state: MobileLocalDirectClientController.State) async {
        while client.state != state {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = client.state } onChange: { continuation.resume() }
            }
        }
    }
    @Test func approvedPairListsOnlyTerminalsAndRemembersSelection() async throws {
        let fixture = MobileDirectClientFixture()
        let client = controller(fixture)
        await client.setForeground(true)
        client.address = "100.70.1.2"
        await client.pair()
        await wait(client, for: .connected)
        #expect(client.isRemembered)
        #expect(client.workspaces.first?.terminals.map(\.id) == ["terminal-a"])
        client.select(workspaceID: "workspace-a", surfaceID: "terminal-a")
        await client.setForeground(false)
        await client.setForeground(true)
        await wait(client, for: .connected)
        #expect(client.selectedSurfaceID == "terminal-a")
        #expect(await fixture.saves == 1)
        await client.disconnect()
        await client.setForeground(false); await client.setForeground(true)
        #expect(client.state == .disconnected)
        #expect(await fixture.opens == 2)
        await client.forget()
        #expect(await fixture.saved == nil)
        #expect(client.selectedSurfaceID == nil)
        await client.setForeground(false)
    }
    @Test func onlyExplicitDisconnectReleasesTerminalControl() async throws {
        let fixture = MobileDirectClientFixture()
        await fixture.configure(saved: try saved())
        let client = controller(fixture)
        await client.setForeground(true)
        await wait(client, for: .connected)
        await client.setForeground(false)
        #expect(await fixture.methods.filter { $0 == "mobile.terminal.viewport" }.isEmpty)
        await client.setForeground(true)
        await wait(client, for: .connected)
        await client.disconnect()
        #expect(await fixture.methods.filter { $0 == "mobile.terminal.viewport" }.count == 1)
        #expect(client.state == .disconnected)
        await client.setForeground(false)
    }

    @Test(arguments: [false, true])
    func persistenceFailureDoesNotPublishConnected(keepsOld: Bool) async throws {
        let fixture = MobileDirectClientFixture()
        let old = keepsOld ? try saved() : nil
        await fixture.configure(saved: old, saveFails: true)
        let client = controller(fixture)
        await client.setForeground(true)
        if keepsOld { await wait(client, for: .connected) }
        client.address = "100.70.1.2"
        await client.pair()
        await wait(client, for: .error(.saveFailed))
        #expect(client.isRemembered == keepsOld)
        #expect(await fixture.saved == old)
        #expect(await fixture.disconnects == (keepsOld ? 2 : 1))
        await client.setForeground(false)
    }
    @Test func corruptRecordNeverDialsOrGetsOverwritten() async {
        let fixture = MobileDirectClientFixture()
        await fixture.configure(broken: true)
        let client = controller(fixture)
        await client.setForeground(true)
        #expect(client.state == .error(.recordUnavailable))
        #expect(await fixture.opens == 0)
        #expect(await fixture.saves == 0)
        await client.forget()
        #expect(client.state == .disconnected)
        await client.setForeground(false)
    }
    @Test(arguments: [false, true])
    func authenticationOrHostMismatchStopsAutomaticReconnect(mismatch: Bool) async throws {
        let fixture = MobileDirectClientFixture()
        await fixture.configure(saved: try saved(), reject: !mismatch,
            hostID: mismatch ? "00000000-0000-0000-0000-000000000099" : MobileDirectClientFixture.hostID)
        let client = controller(fixture)
        await client.setForeground(true)
        await wait(client, for: .error(mismatch ? .hostChanged : .needsApproval))
        client.networkChanged()
        await client.setForeground(false); await client.setForeground(true)
        #expect(await fixture.opens == 1)
        #expect(await fixture.saves == 0)
        await client.setForeground(false)
    }
    @Test func backgroundInvalidatesLateConnectAndNetworkChangesCannotParallelDial() async throws {
        let fixture = MobileDirectClientFixture()
        await fixture.configure(saved: try saved(), hold: true)
        let client = controller(fixture)
        await client.setForeground(true)
        var opens = fixture.opened.stream.makeAsyncIterator()
        #expect(await opens.next() == 1)
        for _ in 0..<20 { client.networkChanged() }
        let stopped = Task { await client.setForeground(false) }
        await wait(client, for: .disconnected)
        await fixture.release()
        await stopped.value
        #expect(await fixture.opens == 1)
        #expect(await fixture.methods.isEmpty)
        #expect(client.state == .disconnected)
    }
    @Test func networkFailureRetriesThroughOneOwner() async throws {
        let fixture = MobileDirectClientFixture()
        await fixture.configure(saved: try saved(), hold: true, openFailures: 1)
        let client = controller(fixture)
        await client.setForeground(true)
        var opens = fixture.opened.stream.makeAsyncIterator()
        #expect(await opens.next() == 1)
        await wait(client, for: .reconnecting)
        for _ in 0..<20 { client.networkChanged() }
        #expect(await opens.next() == 2)
        #expect(await fixture.opens == 2)
        await fixture.release()
        await wait(client, for: .connected)
        #expect(await fixture.saves == 0)
        await client.setForeground(false)
    }
    @Test func authorizationFailureDuringEventRefreshDoesNotRedial() async throws {
        let fixture = MobileDirectClientFixture()
        await fixture.configure(saved: try saved())
        let client = controller(fixture)
        await client.setForeground(true)
        await wait(client, for: .connected)
        await fixture.denyNextListAndEmitChange()
        await wait(client, for: .error(.needsApproval))
        #expect(await fixture.opens == 1)
        await client.setForeground(false)
    }
    @Test(arguments: [false, true])
    func backgroundOrForgetDiscardsLateApprovalWithoutSaving(forgets: Bool) async throws {
        let fixture = MobileDirectClientFixture()
        let client = controller(fixture)
        await client.setForeground(true)
        let old = try saved()
        await fixture.configure(saved: old, holdAdmission: true)
        client.address = "100.70.1.2"
        await client.pair()
        await wait(client, for: .waitingApproval)
        let stopped = Task {
            if forgets { await client.forget() } else { await client.setForeground(false) }
        }
        await wait(client, for: .disconnected)
        await fixture.releaseAdmission()
        await stopped.value
        #expect(await fixture.saved == (forgets ? nil : old))
        #expect(await fixture.saves == 0)
        #expect(await fixture.disconnects == 1)
        #expect(client.state == .disconnected)
        await client.setForeground(false)
    }
    @Test func invalidDraftDoesNotDial() async {
        let fixture = MobileDirectClientFixture()
        let client = controller(fixture)
        await client.setForeground(true)
        client.address = "localhost"
        await client.pair()
        #expect(client.state == .error(.invalidInput))
        #expect(await fixture.opens == 0)
        await client.setForeground(false)
    }
    @Test(arguments: [CmxLocalDirectAdmission.Failure.connectionLost, .timedOut, .invalidResponse, .denied], [false, true])
    func admissionRetryClassification(failure: CmxLocalDirectAdmission.Failure, remembered: Bool) async throws {
        let fixture = MobileDirectClientFixture()
        let old = remembered ? try saved() : nil
        await fixture.configure(saved: old)
        let scenario = DirectAdmissionRetryFixture(failure)
        let client = MobileLocalDirectClientController(store: fixture, connect: { _, _ in try await fixture.open() },
            admit: { _, record in try await scenario.admit(record: record, rpc: fixture) })
        await client.setForeground(true)
        if !remembered { client.address = "100.70.1.2"; await client.pair() }
        while true {
            if client.state == .connected { break }
            if case .error = client.state { break }
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = client.state } onChange: { continuation.resume() }
            }
        }
        let retries: Bool
        switch failure {
        case .connectionLost, .timedOut:
            retries = remembered
            #expect(client.state == (remembered ? .connected : .error(.networkUnavailable)))
        case .denied:
            retries = false
            #expect(client.state == .error(.needsApproval))
        case .invalidResponse:
            retries = false
            #expect(client.state == .error(.incompatibleHost))
        }
        #expect(await scenario.attempts == (retries ? 2 : 1))
        #expect(await scenario.pairAttempts == (remembered ? 0 : 1))
        #expect(await fixture.saved == old)
        await client.setForeground(false)
    }

}
