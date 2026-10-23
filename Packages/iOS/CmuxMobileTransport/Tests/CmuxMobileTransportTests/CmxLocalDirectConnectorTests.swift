import CMUXMobileCore
import Foundation
import Testing
@preconcurrency import Network
@testable import CmuxMobileTransport

@Suite(.timeLimit(.minutes(1)))
struct CmxLocalDirectConnectorTests {
    private func snapshot(_ kind: String = "valid") -> CmxTailscaleAuthoritySnapshot {
        let identity = CmxNetworkInterfaceIdentity(name: kind == "notunnel" ? "en0" : "utun8", index: 8)
        var addresses: Set<CmxTailscaleIPAddress> = [CmxTailscaleIPAddress("100.70.1.2")!]
        if kind == "addresses" { addresses.insert(CmxTailscaleIPAddress("100.70.1.4")!) }
        let owner = CmxTailscaleInterfaceSnapshot(identity: identity, isUp: kind != "down", isRunning: true, addresses: addresses)
        let other = CmxTailscaleInterfaceSnapshot(identity: .init(name: "utun9", index: 9), isUp: true, isRunning: true,
            addresses: [CmxTailscaleIPAddress("100.70.1.5")!])
        return .init(generation: 1, pathSatisfied: kind != "unsatisfied", availableInterfaces: [identity, other.identity],
            systemInterfaces: kind == "multiple" ? [owner, other] : [owner])
    }

    @Test func clientProofSelectsUniqueInterface() throws {
        let proof = try CmxLocalTCPRouteProof.prepareClient(peerAddress: "100.70.1.3", snapshot: snapshot())
        #expect(proof.interface == .init(name: "utun8", index: 8))
        #expect(proof.localIPv4 == CmxTailscaleIPAddress("100.70.1.2"))
    }

    @Test(arguments: ["self", "reserved", "addresses", "multiple", "notunnel", "down", "unsatisfied"])
    func rejectsUnprovenDestinations(_ kind: String) {
        #expect(throws: CmxLocalTCPRouteProof.Failure.self) {
            try CmxLocalTCPRouteProof.prepareClient(peerAddress: kind == "self" ? "100.70.1.2" :
                kind == "reserved" ? "100.100.100.100" : "100.70.1.3", snapshot: snapshot(kind))
        }
    }
    @Test(arguments: ["valid", "remote", "port", "local", "localport", "interface", "type", "path"])
    func effectiveClientEndpoints(_ kind: String) throws {
        let proof = try CmxLocalTCPRouteProof.prepareClient(peerAddress: "100.70.1.3", snapshot: snapshot())
        let operation = {
            try proof.validateClientConnection(isSatisfied: kind != "path", interfaces: kind == "interface" ? [] : [proof.interface],
                usesRequiredType: kind != "type", localAddress: kind == "local" ? nil : proof.localIPv4,
                localPort: kind == "localport" ? 0 : 55000,
                remoteAddress: CmxTailscaleIPAddress(kind == "remote" ? "100.70.1.4" : "100.70.1.3"),
                remotePort: kind == "port" ? 9 : 49443, peerAddress: "100.70.1.3", peerPort: 49443, snapshot: snapshot())
        }
        if kind == "valid" { try operation() }
        else { #expect(throws: CmxLocalTCPRouteProof.Failure.self) { try operation() } }
    }

    @Test(arguments: ["localhost", "127.0.0.1", "100.100.100.100", "100.70.01.2", " 100.70.1.2", "::1"])
    func invalidHostNeverPrepares(_ host: String) async {
        let authority = LocalDirectClientRouteFixture()
        let connector = CmxLocalDirectConnector(makeAuthority: { authority })
        await #expect(throws: CmxLocalDirectConnector.Failure.invalidDestination) {
            try await connector.connect(host: host, port: 49443)
        }
        #expect(await authority.prepares == 0)
    }

    @Test(arguments: [0, -1, 65536])
    func invalidPortNeverPrepares(_ port: Int) async {
        let authority = LocalDirectClientRouteFixture()
        await #expect(throws: CmxLocalDirectConnector.Failure.invalidDestination) {
            try await CmxLocalDirectConnector(makeAuthority: { authority }).connect(host: "100.70.1.3", port: port)
        }
        #expect(await authority.prepares == 0)
    }

    @Test(arguments: [false, true])
    func rejectedProofNeverSendsPairing(authenticate: Bool) async throws {
        let authority = LocalDirectClientRouteFixture(reject: true)
        let connector = CmxLocalDirectConnector(makeAuthority: { authority }, permitsLoopbackForTesting: true)
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { _ in
            Issue.record("Proof failure must not create a native connection")
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("listener"); return }
        await #expect(throws: CmxLocalDirectConnector.Failure.vpnUnavailable) {
            let transport = try await connector.connect(host: host, port: port)
            if authenticate {
                _ = try await CmxLocalDirectAdmission.authenticate(deviceID: UUID().uuidString.lowercased(),
                    token: Data(repeating: 42, count: 32), transport: transport)
            } else { _ = try await CmxLocalDirectAdmission.pair(displayName: "Fixture", transport: transport) }
        }
        #expect(await authority.stops == 1)
        await listener.stop()
    }

    @Test func connectorPairsAndExchangesRPC() async throws {
        let storage = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: storage, storageScope: "connector")
        try await store.load()
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in true }, isCurrent: { true })
        let frame = try MobileSyncFrameCodec.encodeFrame(Data("{\"id\":1,\"method\":\"mobile.host.status\"}".utf8))
        let completion = AsyncStream<Bool>.makeStream()
        defer { completion.continuation.finish() }
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do {
                let accepted = try await admission.accept(stream)
                #expect(try await accepted.transport.receive() == frame)
                try await accepted.transport.send(frame)
                completion.continuation.yield(true)
            } catch { Issue.record(error); completion.continuation.yield(false) }
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("listener"); return }
        let authority = LocalDirectClientRouteFixture()
        let transport = try await CmxLocalDirectConnector(makeAuthority: { authority }, permitsLoopbackForTesting: true)
            .connect(host: host, port: port)
        let paired = try await CmxLocalDirectAdmission.pair(displayName: "Fixture", transport: transport)
        #expect(paired.issuedToken?.count == 32)
        try await paired.transport.send(frame)
        #expect(try await paired.transport.receive() == frame)
        var finished = completion.stream.makeAsyncIterator()
        #expect(await finished.next() == true)
        await paired.transport.close()
        #expect(await authority.stops == 1)
        #expect(await authority.validations > 1)
        await listener.stop()
    }

    @Test(arguments: ["prepare", "validate"])
    func cancellationClosesPreparationOrReadyAttempt(_ phase: String) async throws {
        let authority = LocalDirectClientRouteFixture(hold: phase)
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do { #expect(try await stream.receive() == nil, "No token may precede the ready-path proof") } catch {}
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("listener"); return }
        let task = Task {
            try await CmxLocalDirectConnector(makeAuthority: { authority }, permitsLoopbackForTesting: true)
                .connect(host: host, port: port)
        }
        for await event in authority.events.stream { if event == phase { break } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await authority.stops == 1)
        await listener.stop()
    }

    @Test(arguments: [false, true])
    func invalidationClosesIdleAndBlockedIO(blocked: Bool) async throws {
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do { _ = try await stream.receive() } catch {}
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("listener"); return }
        let authority = LocalDirectClientRouteFixture()
        let transport = try await CmxLocalDirectConnector(makeAuthority: { authority }, permitsLoopbackForTesting: true)
            .connect(host: host, port: port)
        let receive = blocked ? Task { try await transport.receive() } : nil
        if blocked {
            var checks = 0
            for await event in authority.events.stream {
                if event == "validate" { checks += 1 }
                if checks == 2 { break }
            }
        }
        await authority.revoke()
        if let receive { await #expect(throws: (any Error).self) { try await receive.value } }
        await #expect(throws: (any Error).self) { try await transport.send(Data("secret".utf8)) }
        await transport.close()
        #expect(await authority.stops == 1)
        await listener.stop()
    }

    @Test func admissionDenialClosesClientMonitor() async throws {
        let storage = LocalDeviceMemoryStorage()
        let store = try CmxLocalDeviceCredentialStore(storage: storage, storageScope: "connector-deny")
        try await store.load()
        let admission = CmxLocalDirectAdmission(store: store, approval: { _ in false }, isCurrent: { true })
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do { _ = try await admission.accept(stream); Issue.record("Pair must be denied") } catch {}
        }
        await listener.start()
        guard case let .listening(host, port) = await listener.state else { Issue.record("listener"); return }
        let authority = LocalDirectClientRouteFixture()
        let transport = try await CmxLocalDirectConnector(makeAuthority: { authority }, permitsLoopbackForTesting: true)
            .connect(host: host, port: port)
        await #expect(throws: CmxLocalDirectAdmission.Failure.denied) {
            try await CmxLocalDirectAdmission.pair(displayName: "Fixture", transport: transport)
        }
        #expect(await authority.stops == 1)
        await listener.stop()
    }

    @Test func nativeFailureIsSanitizedAndStopsMonitor() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        let listener = try NWListener(using: parameters)
        let events = AsyncStream<Bool>.makeStream()
        defer { events.continuation.finish(); listener.cancel() }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: events.continuation.yield(true)
            case .cancelled, .failed: events.continuation.yield(false)
            default: break
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "connector-refusal-fixture"))
        var iterator = events.stream.makeAsyncIterator()
        try #require(await iterator.next() == true)
        let port = Int(try #require(listener.port).rawValue)
        listener.cancel()
        try #require(await iterator.next() == false) // Wait for actual OS port release.
        let host = "127.0.0.1"
        let authority = LocalDirectClientRouteFixture()
        await #expect(throws: CmxLocalDirectConnector.Failure.connectionFailed) {
            try await CmxLocalDirectConnector(makeAuthority: { authority }, permitsLoopbackForTesting: true)
                .connect(host: host, port: port)
        }
        #expect(await authority.stops == 1)
    }

    @Test func alreadyCancelledNeverPrepares() async {
        let authority = LocalDirectClientRouteFixture()
        let connector = CmxLocalDirectConnector(makeAuthority: { authority })
        #expect(await authority.prepares == 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connector.connect(host: "100.70.1.3", port: 49443)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await authority.prepares == 0)
    }

}
