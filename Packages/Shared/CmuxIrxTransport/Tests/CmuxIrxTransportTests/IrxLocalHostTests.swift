import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct IrxLocalHostTests {
    private func identity() -> IrxIdentity {
        IrxIdentity(privateKeyData: IrxLiveTestSupport.identitySeed(), deviceID: "local-test", appInstanceID: "test")
    }

    @Test(arguments: ["0.0.0.0", "127.0.0.1", "100.63.255.255", "100.128.0.0", "100.064.0.1",
        "100.64.0.1:1234", "host.invalid", "100.64.0.256", " 100.64.0.1", "100.64.0.1."])
    func invalidAddress(_ address: String) {
        #expect(throws: IrxLocalHostConfiguration.ValidationError.invalidAddress) {
            try IrxLocalHostConfiguration(identity: identity(), address: address, port: 1234)
        }
    }

    @Test func validRangeAndPort() throws {
        for address in ["100.64.0.0", "100.127.255.255"] {
            let config = try IrxLocalHostConfiguration(identity: identity(), address: address, port: 65535)
            #expect(config.address == address)
        }
        for port in [0, -1, 65536] {
            #expect(throws: IrxLocalHostConfiguration.ValidationError.invalidPort) {
                try IrxLocalHostConfiguration(identity: identity(), address: "100.64.0.1", port: port)
            }
        }
    }

    @Test func strictBindDoesNotFallbackButDefaultDoes() async throws {
        for fallback in [false, true] {
            var config = IrxEndpointConfiguration(identity: identity(), pathMode: .directOnly,
                preferredBindAddress: "not-an-ip:1234", initialRemoteBiStreams: 1, initialRemoteUniStreams: 0)
            #expect(config.allowsPreferredBindFallback)
            config.allowsPreferredBindFallback = fallback
            let supervisor = IrxEndpointSupervisor(configuration: config, journal: IrxLiveTestSupport.journal())
            do {
                _ = try await supervisor.readyEndpoint(credentials: [])
                #expect(fallback)
                #expect(await supervisor.boundPort() != nil)
            } catch {
                #expect(!fallback)
                #expect(await supervisor.boundEndpoint() == nil)
            }
            await supervisor.deactivate()
        }
    }

    @Test func stopInvalidatesSuspendedStartupAndConcurrentStartJoins() async throws {
        let gate = LocalAuthorizationCredentialFake()
        await gate.blockNext(.read)
        let runtime = IrxLocalHostRuntime(configuration: .loopbackForTesting(identity: identity()),
            current: IrxLocalPeerAuthorizationCurrent(), journal: IrxLiveTestSupport.journal(),
            beforeBind: { _ = try? await gate.read(account: "startup-gate") }) { _, _, _, _, _ in }
        let first = Task { await runtime.start() }
        await gate.waitUntilBlocked()
        #expect(await runtime.state == .starting)
        await runtime.stop()
        #expect(await runtime.state == .stopped)
        await gate.release()
        await first.value
        #expect(await runtime.state == .stopped)
        async let one: Void = runtime.start()
        async let two: Void = runtime.start()
        _ = await (one, two)
        guard case .listening = await runtime.state else {
            Issue.record("Concurrent starts did not establish a listener"); return
        }
        await runtime.notifyNetworkChange()
        await runtime.stop()
    }

    @Test func liveAdmissionRevocationSupersessionAndRestart() async throws {
        let current = IrxLocalPeerAuthorizationCurrent()
        let hostIdentity = identity()
        let (events, continuation) = AsyncStream<IrxAdmittedPeerInfo>.makeStream()
        let runtime = IrxLocalHostRuntime(configuration: .loopbackForTesting(identity: hostIdentity),
            current: current, journal: IrxLiveTestSupport.journal()) { peer, _, _, connection, authorized in
                #expect(authorized(peer.endpointIDHex))
                continuation.yield(peer)
                await connection.waitForClosure(observationID: connection.makeClosureObservationID())
            }
        defer { continuation.finish() }
        await runtime.start()
        guard case let .listening(address, port) = await runtime.state else {
            Issue.record("Expected a loopback listener"); await runtime.stop(); return
        }
        #expect(address == "127.0.0.1")
        await runtime.start()
        #expect(await runtime.state == .listening(boundAddress: address, port: port))
        let clientIdentity = identity()
        let client = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(identity: clientIdentity,
            pathMode: .directOnly, preferredBindAddress: "127.0.0.1:0", initialRemoteBiStreams: 0,
            initialRemoteUniStreams: 0), journal: IrxLiveTestSupport.journal())
        let target = try client.dialAddress(peerEndpointIDHex: hostIdentity.endpointIDHex,
            relayURL: nil, directAddresses: ["\(address):\(port)"])
        let unknown = try await client.dial(address: target, credentials: [])
        await #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) {
            _ = try await IrxAdmission().performClient(connection: unknown, grantJWS: "forged",
                journal: IrxLiveTestSupport.journal())
        }
        let authorization = try IrxLocalPeerAuthorization(endpointIDHex: clientIdentity.endpointIDHex,
            bindingID: "binding", deviceID: "device", tag: "tag", identityGeneration: 1, revoked: false)
        try current.replace([authorization])
        var iterator = events.makeAsyncIterator()
        let first = try await client.dial(address: target, credentials: [])
        _ = try await IrxAdmission().performClient(connection: first, journal: IrxLiveTestSupport.journal())
        #expect(await iterator.next()?.deviceID == "device")
        let second = try await client.dial(address: target, credentials: [])
        _ = try await IrxAdmission().performClient(connection: second, journal: IrxLiveTestSupport.journal())
        #expect(await iterator.next()?.deviceID == "device")
        await first.waitForClosure(observationID: first.makeClosureObservationID())
        #expect(await first.closeReason()?.contains("superseded") == true)
        // Same key and device, but a changed tuple must invalidate the live session.
        try current.replace([IrxLocalPeerAuthorization(endpointIDHex: clientIdentity.endpointIDHex,
            bindingID: "binding", deviceID: "device", tag: "changed", identityGeneration: 2, revoked: false)])
        await runtime.enforceAuthorizations()
        await second.waitForClosure(observationID: second.makeClosureObservationID())
        #expect(await second.closeReason()?.contains("revoked") == true)
        let third = try await client.dial(address: target, credentials: [])
        _ = try await IrxAdmission().performClient(connection: third, journal: IrxLiveTestSupport.journal())
        #expect(await iterator.next()?.tag == "changed")
        try current.replace([IrxLocalPeerAuthorization(endpointIDHex: clientIdentity.endpointIDHex,
            bindingID: "binding", deviceID: "device", tag: "changed", identityGeneration: 2, revoked: true)])
        await runtime.enforceAuthorizations()
        await third.waitForClosure(observationID: third.makeClosureObservationID())
        #expect(await third.closeReason()?.contains("revoked") == true)
        await runtime.stop()
        #expect(await runtime.state == .stopped)
        await runtime.start()
        guard case .listening = await runtime.state else { Issue.record("Restart failed"); return }
        await runtime.stop()
        await client.deactivate()
    }
}
