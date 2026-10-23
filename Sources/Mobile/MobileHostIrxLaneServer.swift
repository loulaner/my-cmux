import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// Shared post-admission dispatcher; local sessions disable auxiliary lane services.
struct MobileHostIrxLaneServer: Sendable {
    let supportsAuxiliaryLanes: Bool

    init(supportsAuxiliaryLanes: Bool = true) {
        self.supportsAuxiliaryLanes = supportsAuxiliaryLanes
    }

    /// Applies lane routing policy before any auxiliary handler is constructed.
    func admitLane(_ kind: IrxLaneKind, reject: () async -> Void) async -> Bool {
        switch kind {
        case .artifact, .simulatorStream, .tcpConnect, .listeningPorts:
            if !supportsAuxiliaryLanes { await reject(); return false }
        default: break
        }
        return true
    }

    /// Post-admission lane dispatch: keepalive echo, terminal streams over
    /// the byte tee, artifact reads. Quotas mirror the legacy router.
    func run(
        _ irx: IrxConnection,
        admittedPeer: CmxIrohAdmittedPeer,
        artifactRegistry: MobileHostIrohArtifactTransferRegistry?,
        controlTransport: IrxControlByteTransport,
        tunnelHost: IrxTunnelHost?,
        journal: IrxJournal,
        onInteractiveSurface: @escaping MobileHostIrxTerminalLaneServer.InteractiveSurfaceObserver,
        onAcceptedInput: @escaping MobileHostIrxTerminalLaneServer.AcceptedInputObserver
    ) async {
        let terminalLaneQuota = MobileHostIrxTerminalLaneQuota()
        while !Task.isCancelled {
            guard let lane = await irx.acceptLane() else { return }
            journal.record(
                "host-lanes", "lane-accepted",
                [
                    "lane": lane.descriptor.lane.rawValue,
                    "resource": lane.descriptor.resource ?? "-",
                ]
            )
            guard await admitLane(lane.descriptor.lane, reject: {
                await lane.writer.reset(errorCode: 2)
                await lane.reader.stop(errorCode: 2)
            }) else { continue }
            switch lane.descriptor.lane {
            case .keepalive:
                _ = irx.respondKeepalive(on: lane)
            case .terminal:
                guard await terminalLaneQuota.reserve() else {
                    await lane.writer.reset(errorCode: 3)
                    await lane.reader.stop(errorCode: 3)
                    continue
                }
                let resource = lane.descriptor.resource ?? ""
                let cursor = lane.descriptor.cursor
                Task {
                    await MobileHostIrxTerminalLaneServer.serve(
                        resourceID: resource,
                        cursor: cursor,
                        stream: lane.bidirectional(),
                        journal: journal,
                        onInteractiveSurface: onInteractiveSurface,
                        onAcceptedInput: onAcceptedInput
                    )
                    await terminalLaneQuota.release()
                }
            case .terminalInput:
                guard await terminalLaneQuota.reserve() else {
                    await lane.writer.reset(errorCode: 3)
                    await lane.reader.stop(errorCode: 3)
                    continue
                }
                let resource = lane.descriptor.resource ?? ""
                Task {
                    await MobileHostIrxTerminalLaneServer.serveInputOnly(
                        resourceID: resource,
                        stream: lane.bidirectional(),
                        journal: journal,
                        onInteractiveSurface: onInteractiveSurface,
                        onAcceptedInput: onAcceptedInput
                    )
                    await terminalLaneQuota.release()
                }
            case .artifact:
                guard let artifactRegistry, let resource = try? CmxIrohResourceID(lane.descriptor.resource ?? "")
                else {
                    await lane.writer.reset(errorCode: 2)
                    await lane.reader.stop(errorCode: 2)
                    continue
                }
                let offset = lane.descriptor.offset ?? 0
                Task {
                    let handler = MobileHostIrohArtifactLaneHandler(registry: artifactRegistry)
                    _ = await handler.handleArtifactLane(
                        resourceID: resource,
                        offset: offset,
                        stream: lane.bidirectional(),
                        peer: admittedPeer
                    )
                }
            case .simulatorStream:
                guard let resource = try? CmxIrohResourceID(lane.descriptor.resource ?? "")
                else {
                    await lane.writer.reset(errorCode: 2)
                    await lane.reader.stop(errorCode: 2)
                    continue
                }
                // No lane count here: the v2 stream coordinator enforces
                // last-writer-wins per panel, so a new attach supersedes and
                // closes the previous session's lane.
                Task {
                    let stream = lane.bidirectional()
                    let handler = MobileHostIrohSimulatorStreamLaneHandler()
                    let didTakeOwnership = await handler.handleSimulatorStreamLane(
                        resourceID: resource,
                        stream: stream,
                        peer: admittedPeer
                    )
                    if !didTakeOwnership {
                        await stream.sendStream.reset(errorCode: 2)
                        await stream.receiveStream.stop(errorCode: 2)
                    }
                }
            case .controlRepair:
                // The phone replaces a silent control stream without closing
                // the connection its terminal lanes share. Off the accept
                // loop: the acknowledgement write must not delay other lanes.
                Task {
                    let replaced = await controlTransport.acceptControlLaneReplacement(lane)
                    journal.record(
                        "host-lanes", replaced ? "control-replaced" : "control-replace-refused")
                }
            case .tcpConnect, .listeningPorts:
                guard let tunnelHost else {
                    await lane.writer.reset(errorCode: 2)
                    await lane.reader.stop(errorCode: 2)
                    continue
                }
                await tunnelHost.accept(lane)
            case .control, .events:
                // control arrives only pre-admission; events is server-opened.
                await lane.writer.reset(errorCode: 2)
                await lane.reader.stop(errorCode: 2)
            }
        }
    }
}
