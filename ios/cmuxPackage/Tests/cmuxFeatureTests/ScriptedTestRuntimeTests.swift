import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import Foundation
import Testing

@Suite struct ScriptedTestRuntimeTests {
    private struct NeverDial: CmxByteTransportFactory {
        func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
            throw MissingTestStackAccessToken()
        }
    }

    @Test func preservesTimeoutsAndFailClosedRefresh() async throws {
        let runtime = testRuntime(transportFactory: NeverDial())
        #expect(runtime.rpcRequestTimeoutNanoseconds == 30_000_000_000)
        #expect(runtime.pairingRequestTimeoutNanoseconds == 30_000_000_000)
        #expect(runtime.pairingAttemptTimeoutNanoseconds == 30_000_000_000)
        #expect(runtime.reconnectAttemptDeadlineNanoseconds == 30_000_000_000)
        #expect(runtime.macDialDeadlineNanoseconds == 10_000_000_000)
        #expect(!runtime.supportsServerPushEvents)
        #expect(try await runtime.stackAccessTokenProvider() == "test-stack-token")
        #expect(await runtime.stackAccessTokenForStatusProvider() == "test-stack-token")
        do {
            _ = try await runtime.stackAccessTokenForceRefresher()
            Issue.record("Default force refresh must not return a test token")
        } catch AuthError.unauthorized {} catch { Issue.record("Unexpected refresh error: \(error)") }
    }

    @Test func preservesMissingTokenAndInjectedConfiguration() async {
        let date = Date(timeIntervalSince1970: 123)
        let runtime = testRuntime(supportedRouteKinds: [.debugLoopback], transportFactory: NeverDial(),
                                  stackAccessToken: nil, rpcRequestTimeoutNanoseconds: 17,
                                  pairingRequestTimeoutNanoseconds: 23, now: { date }, supportsServerPushEvents: true)
        #expect(runtime.supportedRouteKinds == [.debugLoopback])
        #expect(runtime.rpcRequestTimeoutNanoseconds == 17)
        #expect(runtime.pairingRequestTimeoutNanoseconds == 23)
        #expect(runtime.pairingAttemptTimeoutNanoseconds == 30_000_000_000)
        #expect(runtime.now() == date)
        #expect(runtime.supportsServerPushEvents)
        #expect(await runtime.stackAccessTokenForStatusProvider() == nil)
        await #expect(throws: MissingTestStackAccessToken.self) { try await runtime.stackAccessTokenProvider() }
        #expect(runtime.terminalLaneProvider == nil)
        #expect(runtime.artifactLaneProvider == nil)
    }

    @Test func defaultDeadlineSleepsHonorCancellation() async {
        let runtime = testRuntime(transportFactory: NeverDial())
        for reconnect in [true, false] {
            let task = Task {
                if reconnect { try await runtime.sleepUntilReconnectAttemptDeadline(nanoseconds: 30_000_000_000) }
                else { try await runtime.sleepUntilMacDialDeadline(nanoseconds: 30_000_000_000) }
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}
