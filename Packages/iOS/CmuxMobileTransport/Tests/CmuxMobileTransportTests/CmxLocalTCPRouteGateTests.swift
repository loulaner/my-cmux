import Foundation
import Testing
@testable import CmuxMobileTransport

struct CmxLocalTCPRouteGateTests {
    @Test(arguments: ["100.100.0.1", "100.100.100.100", "100.115.92.1", "100.115.93.9"])
    func reservedServiceAddressesCannotListen(_ address: String) {
        #expect(throws: CmxLocalTCPListenerConfiguration.ValidationError.invalidAddress) {
            try CmxLocalTCPListenerConfiguration(address: address, port: 12345)
        }
    }
    private let address = "100.70.1.2"
    private let identity = CmxNetworkInterfaceIdentity(name: "utun9", index: 9)

    private func snapshot(kind: String = "valid") -> CmxTailscaleAuthoritySnapshot {
        let id = CmxNetworkInterfaceIdentity(name: kind == "nonutun" ? "en0" : "utun9", index: kind == "replaced" ? 10 : 9)
        let owner = CmxTailscaleInterfaceSnapshot(identity: id, isUp: kind != "down", isRunning: kind != "notrunning",
            addresses: kind == "removed" ? [] : [CmxTailscaleIPAddress(address)!])
        return .init(generation: 1, pathSatisfied: kind != "unavailable",
            availableInterfaces: kind == "missing" ? [] : [id],
            systemInterfaces: kind == "ambiguous" ? [owner, owner] : [owner])
    }

    @Test(arguments: ["missing", "ambiguous", "nonutun", "down", "notrunning", "removed", "unavailable", "replaced"])
    func changedEvidenceFailsClosed(_ kind: String) throws {
        let proof = try CmxLocalTCPRouteProof.prepare(address: address, snapshot: snapshot())
        #expect(throws: CmxLocalTCPRouteProof.Failure.self) {
            try proof.validate(address: address, snapshot: snapshot(kind: kind))
        }
    }

    @Test(arguments: ["valid", "self", "reserved", "local", "port", "interface", "type", "unsatisfied"])
    func effectiveConnectionPath(_ kind: String) throws {
        let local = CmxTailscaleIPAddress(address)!
        let proof = try CmxLocalTCPRouteProof.prepare(address: address, snapshot: snapshot())
        let validate = {
            try proof.validateConnection(isSatisfied: kind != "unsatisfied", interfaces: kind == "interface" ? [] : [identity],
                usesRequiredType: kind != "type", localAddress: kind == "local" ? nil : local,
                localPort: kind == "port" ? 9 : 1234, expectedPort: 1234,
                remoteAddress: CmxTailscaleIPAddress(kind == "self" ? address : kind == "reserved" ? "100.100.100.100" : "100.70.1.3"),
                selfAddresses: [local])
        }
        if kind == "valid" { try validate() }
        else { #expect(throws: CmxLocalTCPRouteProof.Failure.self) { try validate() } }
    }

    @Test func guardedReceiveDiscardsBytesWhenProofChangesDuringIO() async throws {
        let base = LocalTCPGuardByteProbe()
        let guarded = CmxLocalTCPGuardedTransport(base: base) { try await base.check() }
        try await guarded.connect()
        await #expect(throws: CmxLocalTCPRouteProof.Failure.self) { try await guarded.receive() }
        await #expect(throws: CmxLocalTCPRouteProof.Failure.self) { try await guarded.send(Data("token".utf8)) }
        #expect(await base.closed)
        #expect(await base.sends == 0)
    }

    @Test func absentRouteNeverStartsListener() async throws {
        let authority = LocalTCPControlledRouteAuthority(permitsStartup: false)
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting(), makeAuthority: { authority }) { _ in
            Issue.record("A missing route must never reach the handler")
        }
        await listener.start()
        #expect(await listener.state == .failed)
        await listener.stop()
        await authority.revoke() // A late callback cannot restore or fail a stopped generation.
        #expect(await listener.state == .stopped)
    }

    @Test func liveRevocationClosesPendingIO() async throws {
        let authority = LocalTCPControlledRouteAuthority()
        let (events, continuation) = AsyncStream<Bool>.makeStream()
        defer { continuation.finish() }
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting(), makeAuthority: { authority }) { stream in
            continuation.yield(true)
            do {
                _ = try await stream.receive()
                Issue.record("Revoked receive must not deliver bytes")
            } catch {}
            do {
                try await stream.send(Data("must-not-send".utf8))
                Issue.record("Revoked send must fail")
            } catch {}
            continuation.yield(false)
        }
        await listener.start()
        guard case let .listening(address, port) = await listener.state else {
            Issue.record("Loopback route must start"); return
        }
        let client = try CmxNetworkByteTransport(host: address, port: port)
        try await client.connect()
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == true)
        await authority.revoke()
        #expect(await listener.state == .failed)
        #expect(await iterator.next() == false)
        #expect(try await client.receive() == nil)
        await client.close()
        await listener.stop()
        await authority.revoke()
        #expect(await listener.state == .stopped)
    }

}
