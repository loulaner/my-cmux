import Foundation
import CMUXMobileCore

/// Synthetic admission failures; no real endpoint or capability is used.
actor AdmissionFailureTransport: CmxByteTransport {
    enum Mode: Sendable { case sendLost, readLost, eof, empty, malformed, oversized, denied, cancel, blocked }
    enum Offline: Error { case disconnected }
    let mode: Mode
    private(set) var closed = false
    private let pending = AsyncStream<Data>.makeStream()
    init(_ mode: Mode) { self.mode = mode }
    func connect() {}
    func send(_ data: Data) throws {
        if mode == .sendLost { throw Offline.disconnected }
    }
    func receive() async throws -> Data? {
        switch mode {
        case .sendLost, .readLost: throw Offline.disconnected
        case .eof: return nil
        case .empty: return Data()
        case .malformed: return try MobileSyncFrameCodec.encodeFrame(Data("not-json".utf8))
        case .oversized: return Data([0, 0, 32, 0])
        case .denied: return try MobileSyncFrameCodec.encodeFrame(Data(#"{"version":1,"status":"denied"}"#.utf8))
        case .cancel: throw CancellationError()
        case .blocked:
            for await data in pending.stream { return data }
            return nil
        }
    }
    func close() { closed = true; pending.continuation.finish() }
}
