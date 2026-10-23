import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Testing
import Foundation
import CryptoKit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct MobileLocalTerminalSessionServerTests {
    @Test func dedicatedHostIsolationWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let expectedHome = environment["CMUX_LOCAL_ACCEPTANCE_HOME"] else { return }
        let bundle = "com.cmuxterm.app.debug.local-terminal-acceptance"
        #expect(Bundle.main.bundleIdentifier == bundle)
        #expect(environment["HOME"] == expectedHome)
        #expect(environment["CFFIXED_USER_HOME"] == expectedHome)
        #expect(environment["XDG_CONFIG_HOME"] == expectedHome + "/.config")
        #expect(environment["CMUX_SOCKET_PATH"] == "/tmp/cmux-debug-local-terminal-acceptance.sock")
        #expect(environment["CMUX_TEST_PROCESS"] == "1")
        let domain = try #require(TestProcessDefaults.isolatedDomainName)
        #expect(domain.hasPrefix(bundle + ".xctest."))
        let encoded = try #require(environment["CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64"])
        #expect(Data(base64Encoded: encoded)?.count == 32)
        #expect(environment["SSH_AUTH_SOCK", default: ""].isEmpty)
        for key in ["CMUX_SOCKET", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID"] {
            #expect(environment[key, default: ""].isEmpty)
        }
        // Private receipt contains no credentials, only the verified process identity.
        if let receipt = environment["CMUX_LOCAL_ACCEPTANCE_RECEIPT"] {
            let text = "pid=\(ProcessInfo.processInfo.processIdentifier)\nbundle=\(bundle)\nhome=\(expectedHome)\ndefaults=\(domain)\nsyntheticSecretBytes=32\n"
            try text.write(toFile: receipt, atomically: true, encoding: .utf8)
        }
    }
    @Test func terminalOnlyRejectsAuxiliaryLanesBeforeDispatch() async {
        for kind in [IrxLaneKind.artifact, .simulatorStream, .tcpConnect, .listeningPorts] {
            var rejected = false
            let accepted = await MobileHostIrxLaneServer(supportsAuxiliaryLanes: false).admitLane(kind) {
                rejected = true
            }
            #expect(!accepted)
            #expect(rejected)
            #expect(await MobileHostIrxLaneServer().admitLane(kind) { Issue.record("Full mode rejected a lane") })
        }
        for kind in [IrxLaneKind.keepalive, .terminal, .terminalInput, .controlRepair] {
            #expect(await MobileHostIrxLaneServer(supportsAuxiliaryLanes: false).admitLane(kind) {
                Issue.record("Terminal mode rejected a required lane")
            })
        }
    }

    @Test func staleRevokedAndMismatchedPeersCannotReachRPC() async {
        let key = String(repeating: "ab", count: 32)
        let peer = IrxAdmittedPeerInfo(bindingID: "binding", deviceID: "device", tag: "tag",
            endpointIDHex: key, identityGeneration: 3)
        let stale = MobileLocalTerminalSessionServer(hostDeviceID: "host",
            journal: IrxJournal(subsystem: "test", category: "local"), isCurrent: { false })
        #expect(await stale.admittedPeer(peer, remoteEndpointIDHex: key, stillAuthorized: { _ in true }) == nil)
        let current = MobileLocalTerminalSessionServer(hostDeviceID: "host",
            journal: IrxJournal(subsystem: "test", category: "local"), isCurrent: { true })
        #expect(await current.admittedPeer(peer, remoteEndpointIDHex: key, stillAuthorized: { _ in false }) == nil)
        #expect(await current.admittedPeer(peer, remoteEndpointIDHex: String(repeating: "cd", count: 32),
            stillAuthorized: { _ in true }) == nil)
    }

    @Test func admittedTupleIsPreservedAndManagedPolicyStillDenies() async throws {
        let key = String(repeating: "ab", count: 32)
        let peer = IrxAdmittedPeerInfo(bindingID: "binding", deviceID: "device", tag: "tag",
            endpointIDHex: key, identityGeneration: 3)
        let server = MobileLocalTerminalSessionServer(hostDeviceID: "host",
            journal: IrxJournal(subsystem: "test", category: "local"), isCurrent: { true },
            managedPolicyDisabled: { false })
        let admitted = await server.admittedPeer(peer, remoteEndpointIDHex: key, stillAuthorized: { _ in true })
        let expected = CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(bindingID: "binding", deviceID: "device",
            tag: "tag", platform: .ios, endpointID: try CmxIrohPeerIdentity(endpointID: key), identityGeneration: 3))
        #expect(admitted == expected)
        let denied = MobileLocalTerminalSessionServer(hostDeviceID: "host",
            journal: IrxJournal(subsystem: "test", category: "local"), isCurrent: { true },
            managedPolicyDisabled: { true })
        #expect(await denied.admittedPeer(peer, remoteEndpointIDHex: key, stillAuthorized: { _ in true }) == nil)
    }

    @Test func terminalQuotaReturnsCredit() async {
        let quota = MobileHostIrxTerminalLaneQuota()
        for _ in 0..<4 { #expect(await quota.reserve()) }
        #expect(await quota.reserve() == false)
        await quota.release()
        #expect(await quota.reserve())
    }
    @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 3])
    func realTLSAdapterClosesConnectionAndFinishes(allowedEpochChecks: Int) async throws {
        // 0: adapter rejects immediately; 1: RPC rejects before transport's first
        // read; 3: enter the RPC session and end only the control send stream.
        let journal = IrxJournal(subsystem: "test", category: "local-session-lifetime")
        let hostIdentity = IrxIdentity(privateKeyData: Curve25519.Signing.PrivateKey().rawRepresentation,
            deviceID: "host", appInstanceID: "host-test")
        let clientIdentity = IrxIdentity(privateKeyData: Curve25519.Signing.PrivateKey().rawRepresentation,
            deviceID: "client", appInstanceID: "client-test")
        let host = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(identity: hostIdentity,
            pathMode: .directOnly, preferredBindAddress: "127.0.0.1:0", initialRemoteBiStreams: 1,
            initialRemoteUniStreams: 0, allowsPreferredBindFallback: false), journal: journal)
        let client = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(identity: clientIdentity,
            pathMode: .directOnly, preferredBindAddress: "127.0.0.1:0", initialRemoteBiStreams: 0,
            initialRemoteUniStreams: 0, allowsPreferredBindFallback: false), journal: journal)
        let (checks, checkEvents) = AsyncStream<Int>.makeStream()
        defer { checkEvents.finish() }
        let probe = MobileLocalSessionEpochProbe(allowedChecks: allowedEpochChecks, events: checkEvents)
        let completed = try await withIrxDeadline(.seconds(10), onTimeout: {
            checkEvents.finish()
            await host.deactivate()
            await client.deactivate()
        }) {
            _ = try await host.readyEndpoint(credentials: [])
            let port = try #require(await host.boundPort())
            let current = IrxLocalPeerAuthorizationCurrent()
            try current.replace([IrxLocalPeerAuthorization(endpointIDHex: clientIdentity.endpointIDHex,
                bindingID: "local-binding", deviceID: "client", tag: "test", identityGeneration: 1, revoked: false)])
            let judgment = IrxLocalPeerJudge(current: current).judgment()
            let accepting = Task {
                guard case .irx(let connection) = await host.acceptNextInbound() else {
                    throw IrxEndpointError.endpointClosed
                }
                let admitted = try #require(await IrxAdmission().performServer(
                    connection: connection, judgment: judgment, journal: journal))
                return (connection, admitted)
            }
            let target = try client.dialAddress(peerEndpointIDHex: hostIdentity.endpointIDHex,
                relayURL: nil, directAddresses: ["127.0.0.1:\(port)"])
            let remote = try await client.dial(address: target, credentials: [])
            let (_, clientControl) = try await IrxAdmission().performClient(connection: remote, journal: journal)
            let (connection, (peer, control, sessionID)) = try await accepting.value
            let server = MobileLocalTerminalSessionServer(hostDeviceID: "host", journal: journal,
                isCurrent: { await probe.isCurrent() }, managedPolicyDisabled: { false })
            let serving = Task {
                await server.serve(peer: peer, control: control, sessionID: sessionID,
                    connection: connection, stillAuthorized: { key in (try? judgment(nil, key)) == peer })
            }
            if allowedEpochChecks == 3 {
                for await check in checks { if check == 3 { break } }
                // FIN, not connection.close(): the real adapter must retire the
                // connection and release its own blocked lane acceptance task.
                await clientControl.writer.finish()
            }
            await serving.value
            #expect(await connection.isConnectionClosed())
            await remote.waitForClosure(observationID: remote.makeClosureObservationID())
            #expect(await remote.isConnectionClosed())
            return true
        }
        await host.deactivate()
        await client.deactivate()
        #expect(completed == true, "Adapter or native lane acceptance did not finish before the deadline")
    }

}
