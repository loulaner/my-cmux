import CMUXMobileCore
import Foundation

/// Scripted framing peer with observable writes; no Stack or route provider exists.
actor LocalDirectRPCTransport: CmxByteTransport {
    let writes = AsyncStream<Data>.makeStream()
    private var chunks: [Data] = []
    private var receiver: CheckedContinuation<Data?, Never>?
    private(set) var connects = 0
    private(set) var closes = 0
    private var closed = false
    private var receiveFinished = false
    private let automatic: Bool
    init(automatic: Bool = false) { self.automatic = automatic }

    func connect() throws { connects += 1; if closed { throw CancellationError() } }
    func send(_ data: Data) throws {
        guard !closed else { throw CancellationError() }
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            writes.continuation.yield(payload)
            if automatic, let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let id = object["id"] as? String {
                try deliverJSON("{\"id\":\"\(id)\",\"ok\":true,\"result\":{\"value\":\"\(id)\"}}")
            }
        }
    }
    func receive() async -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if closed || receiveFinished { return nil }
        return await withCheckedContinuation { receiver = $0 }
    }
    func deliverJSON(_ json: String) throws {
        let frame = try MobileSyncFrameCodec.encodeFrame(Data(json.utf8))
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { chunks.append(frame) }
    }
    func finishReceiving() {
        receiveFinished = true
        receiver?.resume(returning: nil)
        receiver = nil
    }
    func close() {
        closes += 1
        closed = true
        receiver?.resume(returning: nil)
        receiver = nil
        writes.continuation.finish()
    }
}
