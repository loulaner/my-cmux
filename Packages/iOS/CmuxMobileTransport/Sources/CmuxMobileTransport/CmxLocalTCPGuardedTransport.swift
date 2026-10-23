import CMUXMobileCore
import Foundation

/// Checks live evidence at each byte boundary without stealing the native path callback.
actor CmxLocalTCPGuardedTransport: CmxByteTransport {
    private let base: any CmxByteTransport
    private let validate: @Sendable () async throws -> Void
    private let onClose: @Sendable () async -> Void
    private var closed = false
    init(base: any CmxByteTransport, onClose: @escaping @Sendable () async -> Void = {}, validate: @escaping @Sendable () async throws -> Void) {
        self.onClose = onClose
        self.base = base
        self.validate = validate
    }
    func connect() async throws {
        do {
            try await base.connect()
            try await check()
        } catch { await close(); throw error }
    }
    func send(_ data: Data) async throws {
        do {
            try await check()
            try await base.send(data)
        } catch { await close(); throw error }
    }
    func receive() async throws -> Data? {
        do {
            try await check()
            let data = try await base.receive()
            try await check()
            return data
        } catch { await close(); throw error }
    }
    func check() async throws {
        do {
            guard !closed else { throw CmxLocalTCPRouteProof.Failure.unavailable }
            try await validate()
            guard !closed else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        } catch {
            await close()
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
    }
    func close() async {
        guard !closed else { return }
        closed = true
        await base.close()
        await onClose()
    }
}
