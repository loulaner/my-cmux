import CMUXMobileCore
import os

/// Single synchronous handoff into the existing session factory; retirement wins atomically.
final class MobileLocalDirectTransportOwner: Sendable {
    // Carve-out: the session factory is synchronous; this lock only transfers ownership once.
    private let transport: OSAllocatedUnfairLock<(any CmxByteTransport)?>

    init(_ transport: any CmxByteTransport) { self.transport = .init(initialState: transport) }

    func claim() throws -> any CmxByteTransport {
        try transport.withLock { value in
            guard let claimed = value else { throw MobileShellConnectionError.connectionClosed }
            value = nil
            return claimed
        }
    }

    func retire() -> (any CmxByteTransport)? {
        transport.withLock { value in
            let unclaimed = value
            value = nil
            return unclaimed
        }
    }
}
