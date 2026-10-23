import Foundation
@testable import CmuxIrxTransport

/// Injects only accept outcomes; successful connections still use real native TLS.
actor IrxLocalHostAcceptProbe {
    private var calls = 0
    private let first: IrxEndpointSupervisor.AcceptResult
    private let events: AsyncStream<Int>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private let suspendFirst: Bool

    init(first: IrxEndpointSupervisor.AcceptResult, events: AsyncStream<Int>.Continuation,
         suspendFirst: Bool = false) {
        self.first = first
        self.events = events
        self.suspendFirst = suspendFirst
    }

    func next(_ endpoint: IrxEndpointSupervisor) async -> IrxEndpointSupervisor.AcceptResult {
        calls += 1
        if calls == 1, suspendFirst {
            await withCheckedContinuation { continuation in
                gate = continuation
                events.yield(calls)
            }
        } else { events.yield(calls) }
        if calls == 1 { return first }
        return await endpoint.acceptNextInboundResult()
    }

    func release() { gate?.resume(); gate = nil }
    var count: Int { calls }
}
