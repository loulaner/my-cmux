import CMUXMobileCore
import Foundation

/// Output acknowledgement seam, not proof of actual GPU/UI rendering.
@MainActor
final class DirectTerminalRenderSink {
    private(set) var frames: [MobileTerminalRenderGridFrame] = []
    private(set) var bytes = Data()
    let applied = AsyncStream<UInt64>.makeStream()
    func apply(_ frame: MobileTerminalRenderGridFrame, _ data: Data) async -> Bool {
        frames.append(frame); bytes.append(data); applied.continuation.yield(frame.renderRevision); return true
    }
}
