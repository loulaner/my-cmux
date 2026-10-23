import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct IrxLocalHostAcceptTests {
    private func identity() -> IrxIdentity {
        IrxIdentity(privateKeyData: IrxLiveTestSupport.identitySeed(), deviceID: "accept-test", appInstanceID: "test")
    }

    @Test func failedHandshakeDoesNotPreventAuthorizedTLSAdmission() async throws {
        let (attempts, attemptEvents) = AsyncStream<Int>.makeStream()
        let probe = IrxLocalHostAcceptProbe(first: .handshakeFailed, events: attemptEvents)
        let (handled, handlerEvents) = AsyncStream<String>.makeStream()
        defer { attemptEvents.finish(); handlerEvents.finish() }
        let current = IrxLocalPeerAuthorizationCurrent()
        let hostID = identity()
        let clientID = identity()
        try current.replace([IrxLocalPeerAuthorization(endpointIDHex: clientID.endpointIDHex,
            bindingID: "binding", deviceID: "device", tag: "tag", identityGeneration: 1, revoked: false)])
        let runtime = IrxLocalHostRuntime(configuration: .loopbackForTesting(identity: hostID),
            current: current, journal: IrxLiveTestSupport.journal(), beforeBind: {},
            acceptInbound: { await probe.next($0) }) { peer, _, _, connection, authorized in
                #expect(authorized(peer.endpointIDHex))
                handlerEvents.yield(peer.deviceID)
                await connection.waitForClosure(observationID: connection.makeClosureObservationID())
            }
        await runtime.start()
        let continued = try await withIrxDeadline(.seconds(1), onTimeout: { attemptEvents.finish() }) {
            for await attempt in attempts { if attempt == 2 { return true } }
            return false
        }
        guard continued == true else {
            Issue.record("One failed handshake stopped acceptance instead of consuming the next incoming peer")
            await runtime.stop()
            return
        }
        guard case let .listening(address, port) = await runtime.state else {
            Issue.record("Handshake failure must leave the listener running"); await runtime.stop(); return
        }
        let client = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(identity: clientID,
            pathMode: .directOnly, preferredBindAddress: "127.0.0.1:0", initialRemoteBiStreams: 0,
            initialRemoteUniStreams: 0), journal: IrxLiveTestSupport.journal())
        let target = try client.dialAddress(peerEndpointIDHex: hostID.endpointIDHex,
            relayURL: nil, directAddresses: ["\(address):\(port)"])
        let connection = try await client.dial(address: target, credentials: [])
        _ = try await IrxAdmission().performClient(connection: connection, journal: IrxLiveTestSupport.journal())
        var iterator = handled.makeAsyncIterator()
        #expect(await iterator.next() == "device")
        #expect(await runtime.state == .listening(boundAddress: address, port: port))
        await runtime.stop()
        await client.deactivate()
    }

    @Test(arguments: [false, true])
    func closedStopsAndStopRacingFailureDoesNotRevive(stopFirst: Bool) async throws {
        let (attempts, events) = AsyncStream<Int>.makeStream()
        defer { events.finish() }
        let probe = IrxLocalHostAcceptProbe(first: stopFirst ? .handshakeFailed : .closed,
            events: events, suspendFirst: true)
        let runtime = IrxLocalHostRuntime(configuration: .loopbackForTesting(identity: identity()),
            current: IrxLocalPeerAuthorizationCurrent(), journal: IrxLiveTestSupport.journal(),
            beforeBind: {}, acceptInbound: { await probe.next($0) }) { _, _, _, _, _ in
                Issue.record("No session should be admitted")
            }
        await runtime.start()
        var iterator = attempts.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        let loop = await runtime.acceptLoopForTesting()
        if stopFirst { await runtime.stop() }
        await probe.release()
        // Join the owned accept task rather than polling lifecycle state.
        await loop?.value
        #expect(await runtime.state == (stopFirst ? .stopped : .failed(.acceptFailed)))
        #expect(await probe.count == 1)
        await runtime.stop()
    }
}
