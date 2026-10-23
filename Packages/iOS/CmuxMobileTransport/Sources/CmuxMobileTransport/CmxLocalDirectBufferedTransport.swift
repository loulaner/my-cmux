import CMUXMobileCore
import Foundation

/// Replays only the bytes coalesced after admission, then delegates to the live-gated stream.
actor CmxLocalDirectBufferedTransport: CmxByteTransport {
    private let base: any CmxByteTransport
    private var buffered: Data
    private var closed = false
    private let isCurrent: @Sendable () async -> Bool
    init(base: any CmxByteTransport, buffered: Data, isCurrent: @escaping @Sendable () async -> Bool) {
        self.base = base
        self.buffered = buffered
        self.isCurrent = isCurrent
    }
    func connect() async throws { try await check() }
    private func check() async throws {
        if let guarded = base as? CmxLocalTCPGuardedTransport { try await guarded.check() }
        guard !closed, !Task.isCancelled, await isCurrent() else {
            await close()
            throw CmxLocalDirectAdmission.Failure.denied
        }
    }
    func receive() async throws -> Data? {
        try await check()
        if !buffered.isEmpty {
            let bytes = buffered
            buffered.removeAll()
            return bytes
        }
        return try await base.receive()
    }
    func send(_ data: Data) async throws { try await check(); try await base.send(data) }
    func close() async { closed = true; buffered.removeAll(); await base.close() }
}
