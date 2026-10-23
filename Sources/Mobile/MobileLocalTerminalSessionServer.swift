import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// Adapts an already locally admitted TLS session to the existing terminal RPC service.
struct MobileLocalTerminalSessionServer: Sendable {
    let hostDeviceID: String
    let journal: IrxJournal
    let isCurrent: @Sendable () async -> Bool
    private let managedPolicyDisabled: @Sendable () -> Bool

    init(hostDeviceID: String, journal: IrxJournal,
         isCurrent: @escaping @Sendable () async -> Bool,
         managedPolicyDisabled: @escaping @Sendable () -> Bool = { MobileRemoteControlPolicy.isDisabled }) {
        self.hostDeviceID = hostDeviceID
        self.journal = journal
        self.isCurrent = isCurrent
        self.managedPolicyDisabled = managedPolicyDisabled
    }

    /// Rechecks lifecycle and authorization before translating the exact admitted tuple.
    func admittedPeer(
        _ peer: IrxAdmittedPeerInfo, remoteEndpointIDHex: String,
        stillAuthorized: @Sendable (String) -> Bool
    ) async -> CmxIrohAdmittedPeer? {
        guard await isCurrent(), !Task.isCancelled,
              remoteEndpointIDHex == peer.endpointIDHex,
              stillAuthorized(remoteEndpointIDHex), !managedPolicyDisabled() else { return nil }
        guard let endpoint = try? CmxIrohPeerIdentity(endpointID: peer.endpointIDHex) else { return nil }
        return CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: peer.bindingID, deviceID: peer.deviceID, tag: peer.tag,
            platform: .ios, endpointID: endpoint, identityGeneration: peer.identityGeneration))
    }

    /// Runs within the local runtime's existing session task; registry ownership stays there.
    func serve(
        peer: IrxAdmittedPeerInfo, control: IrxLaneStream, sessionID: String,
        connection: IrxConnection, stillAuthorized: @escaping @Sendable (String) -> Bool
    ) async {
        guard let admitted = await admittedPeer(peer, remoteEndpointIDHex: connection.remoteEndpointIDHex,
            stillAuthorized: stillAuthorized) else {
            await connection.close(code: .revoked, origin: .local)
            return
        }
        let eventWriter = MobileHostIrxEventWriter(connection: connection, journal: journal)
        let transport = IrxControlByteTransport(connection: connection, control: control, closeCode: .hostShutdown)
        let lanes = Task {
            await MobileHostIrxLaneServer(supportsAuxiliaryLanes: false).run(
                connection, admittedPeer: admitted, artifactRegistry: nil,
                controlTransport: transport, tunnelHost: nil, journal: journal,
                onInteractiveSurface: { surfaceID in
                    Task { await eventWriter.noteInteractiveSurface(surfaceID.uuidString) }
                },
                onAcceptedInput: { surfaceID in
                    await MainActor.run {
                        MobileHostService.shared.noteIrohTerminalInputActivity(
                            surfaceID: surfaceID, bindingID: admitted.bindingID)
                    }
                })
        }
        _ = await MobileHostService.acceptTransport(
            transport, authorization: .irohAdmission(admitted), hostDeviceID: hostDeviceID,
            artifactTransfers: nil, independentEventWriter: eventWriter, firstFrameTimeoutNanoseconds: 0,
            irohAdmissionIsAuthorized: { stillAuthorized(peer.endpointIDHex) },
            remoteControlDisabledByPolicy: {
                managedPolicyDisabled() || !stillAuthorized(peer.endpointIDHex)
            },
            peerRequestHandler: nil, isCurrent: isCurrent)
        lanes.cancel()
        // The transport connects lazily: an early policy/epoch rejection may
        // leave its pair nil, so transport.close() alone cannot unblock accept.
        await connection.close(code: .hostShutdown, origin: .local)
        await eventWriter.close()
        await transport.close()
        await lanes.value
    }
}
