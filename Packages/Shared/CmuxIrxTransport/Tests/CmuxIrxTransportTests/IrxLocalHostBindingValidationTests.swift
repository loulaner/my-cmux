import Testing
import Foundation
import IrohLib
@testable import CmuxIrxTransport

struct IrxLocalHostBindingValidationTests {
    @Test(arguments: [[], ["0.0.0.0:1234"], ["[::]:1234"], ["[::1]:1234"],
        ["100.64.0.1:1234", "100.64.0.2:1234"], ["100.64.0.1:1234", "[::]:1234"],
        ["100.64.0.1:1235"], ["100.64.0.1:0"], ["100.64.0.1:65536"],
        ["100.64.0.1:01234"], ["100.64.0.1:+1234"], ["100.64.0.1:1234 "],
        ["100.064.0.1:1234"], ["host:1234"], ["100.64.0.1:1234:1234"]])
    func rejectsMismatch(sockets: [String]) {
        #expect(throws: IrxLocalHostBindingValidation.Failure.self) {
            try IrxLocalHostBindingValidation().port(sockets: sockets,
                requestedAddress: "100.64.0.1", requestedPort: 1234)
        }
    }

    @Test func exactSocketAndEphemeralLoopback() throws {
        let validator = IrxLocalHostBindingValidation()
        #expect(try validator.port(sockets: ["100.64.0.1:1234"],
            requestedAddress: "100.64.0.1", requestedPort: 1234) == 1234)
        #expect(try validator.port(sockets: ["127.0.0.1:4321"],
            requestedAddress: "127.0.0.1", requestedPort: 0) == 4321)
        #expect(throws: IrxLocalHostBindingValidation.Failure.self) {
            try validator.port(sockets: ["127.0.0.1:4321", "127.0.0.1:4322"],
                requestedAddress: "127.0.0.1", requestedPort: 0)
        }
    }
    @Test func nativeLoopbackBindingReportsOnlyRequestedInterface() async throws {
        let endpoint = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let sockets = endpoint.boundSockets()
        // Preserve the actual native bind evidence, not discovered candidates.
        #expect(sockets.allSatisfy { $0.hasPrefix("127.0.0.1:") }, "Native bound sockets: \(sockets)")
        try await endpoint.close()
    }

    @Test func unexpectedNativeSocketFailsClosedBeforeAccept() async throws {
        let (observed, continuation) = AsyncStream<Endpoint>.makeStream()
        defer { continuation.finish() }
        let identity = IrxIdentity(privateKeyData: IrxLiveTestSupport.identitySeed(),
            deviceID: "bind-test", appInstanceID: "bind-test")
        let runtime = IrxLocalHostRuntime(configuration: .loopbackForTesting(identity: identity),
            current: IrxLocalPeerAuthorizationCurrent(), journal: IrxLiveTestSupport.journal(),
            beforeBind: {}, acceptInbound: { _ in
                Issue.record("Rejected bindings must never begin accepting")
                return .closed
            }, boundSockets: { endpoint in
                continuation.yield(endpoint)
                return endpoint.boundSockets() + ["[::]:1234"]
            }) { _, _, _, _, _ in Issue.record("Rejected bindings cannot invoke a handler") }
        await runtime.start()
        #expect(await runtime.state == .failed(.bindFailed))
        continuation.finish()
        var iterator = observed.makeAsyncIterator()
        let native = try #require(await iterator.next())
        #expect(native.isClosed())
        await runtime.stop()
    }

}
