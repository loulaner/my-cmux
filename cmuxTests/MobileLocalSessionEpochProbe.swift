import Foundation

/// Signals adapter/RPC lifecycle checks without sleeps or shared mutable globals.
actor MobileLocalSessionEpochProbe {
    private var checks = 0
    private let allowedChecks: Int
    private let events: AsyncStream<Int>.Continuation

    init(allowedChecks: Int, events: AsyncStream<Int>.Continuation) {
        self.allowedChecks = allowedChecks
        self.events = events
    }

    func isCurrent() -> Bool {
        checks += 1
        events.yield(checks)
        return checks <= allowedChecks
    }
}
