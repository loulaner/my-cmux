import CMUXMobileCore
import Foundation
import Testing
import os
@testable import CmuxMobileRPC

@Suite(.timeLimit(.minutes(1)))
struct MobileRPCReservationTests {
    private func request(_ id: String) -> Data { Data("{\"id\":\"\(id)\",\"method\":\"workspace.list\"}".utf8) }

    @Test(arguments: [false, true], ["share", "cancel", "teardown"])
    func overlappingReservations(keyed: Bool, operation: String) async throws {
        let registry = MobileRPCConnectAttemptRegistry()
        let barrier = RPCReservationBarrier()
        let transport = LocalDirectRPCTransport(automatic: true)
        let owner = MobileLocalDirectTransportOwner(transport)
        // Counts a synchronous ownership transfer, not ongoing asynchronous state.
        let claims = OSAllocatedUnfairLock(initialState: 0)
        let route = try CmxAttachRoute(id: "reservation-test", kind: .debugLoopback, endpoint: .hostPort(host: "127.0.0.1", port: 49443))
        let session = MobileCoreRPCSession(connectAttemptKey: keyed ? .init(route: route) : nil,
            connectAttemptRegistry: registry, makeTransport: {
                claims.withLock { $0 += 1 }
                return try owner.claim()
            }, connectReservationHook: { await barrier.enter() },
            connectReservationWaitHook: { await barrier.enter() })
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let first = Task { try await session.send(payload: request("first"), requestID: "first", deadlineUptimeNanoseconds: deadline) }
        var arrivals = barrier.arrivals.stream.makeAsyncIterator()
        #expect(await arrivals.next() == 1)
        let second = Task { try await session.send(payload: request("second"), requestID: "second", deadlineUptimeNanoseconds: deadline) }
        #expect(await arrivals.next() == 2)
        if operation == "cancel" { first.cancel() }
        if operation == "teardown" { await session.tearDown(error: .connectionClosed) }
        await barrier.release()
        for (index, task) in [first, second].enumerated() {
            do {
                let data = try await task.value
                #expect(operation != "teardown" && !(operation == "cancel" && index == 0))
                let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
                #expect(result["value"] == (index == 0 ? "first" : "second"))
            } catch is CancellationError { #expect(operation == "cancel" && index == 0) }
            catch {
                #expect(operation == "teardown", "Unexpected failure: \(error)")
            }
        }
        #expect(claims.withLock { $0 } == (operation == "teardown" ? 0 : 1))
        #expect(await transport.connects == (operation == "teardown" ? 0 : 1))
        #expect(await transport.closes == 0)
        await session.tearDown(error: .connectionClosed)
        await session.waitForTransportDrain()
        if let unclaimed = owner.retire() { await unclaimed.close() }
        #expect(await transport.closes == 1)
        // The entire admission budget must be free, including untracked leases.
        var leases: [MobileRPCConnectAttemptLease] = []
        for _ in 0..<MobileRPCConnectAttemptRegistry.maximumGlobalOutstandingAttempts {
            if case let .granted(lease) = await registry.beginConnect(key: nil) { leases.append(lease) }
        }
        #expect(leases.count == MobileRPCConnectAttemptRegistry.maximumGlobalOutstandingAttempts)
        for lease in leases { await registry.finishConnect(lease: lease) }
    }
    @Test func waitingReservationKeepsItsOwnDeadline() async throws {
        let barrier = RPCReservationBarrier()
        let transport = LocalDirectRPCTransport(automatic: true)
        let owner = MobileLocalDirectTransportOwner(transport)
        let session = MobileCoreRPCSession(makeTransport: { try owner.claim() },
            connectReservationHook: { await barrier.enter() })
        let first = Task { try await session.send(payload: request("first"), requestID: "first",
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }
        var arrivals = barrier.arrivals.stream.makeAsyncIterator()
        #expect(await arrivals.next() == 1)
        do {
            _ = try await session.send(payload: request("second"), requestID: "second",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000)
            Issue.record("The wait must expire without releasing the owner's barrier")
        } catch let error as MobileShellConnectionError {
            if case .requestTimedOut = error {} else { Issue.record(error) }
        }
        #expect(await transport.connects == 0)
        await barrier.release()
        _ = try await first.value
        #expect(await transport.connects == 1)
        await session.tearDown(error: .connectionClosed)
        await session.waitForTransportDrain()
        #expect(await transport.closes == 1)
    }

}
