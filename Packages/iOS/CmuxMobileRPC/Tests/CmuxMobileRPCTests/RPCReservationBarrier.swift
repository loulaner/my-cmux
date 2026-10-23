import Foundation

/// Holds reservation completions until the test explicitly releases them.
actor RPCReservationBarrier {
    let arrivals = AsyncStream<Int>.makeStream()
    private var count = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        count += 1
        arrivals.continuation.yield(count)
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        released = true
        let pending = waiting
        waiting.removeAll()
        for waiter in pending { waiter.resume() }
        arrivals.continuation.finish()
    }
}
