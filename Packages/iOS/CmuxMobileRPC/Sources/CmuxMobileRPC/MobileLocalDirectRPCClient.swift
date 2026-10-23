public import CMUXMobileCore
public import Foundation

/// A single admitted direct connection using the existing multiplexed RPC engine.
///
/// Pass only `CmxLocalDirectAdmission.Accepted.transport` or
/// `CmxLocalDirectAdmission.ClientAccepted.transport`, never an unproven raw stream.
/// This client stores no credentials, performs no admission, and cannot reconnect.
/// The caller must create a fresh connector, admission, and client after disconnect.
/// Admission's buffered transport makes `connect()` an authorization check, not
/// another TCP connection or handshake. Top-level legacy credential fields are
/// rejected; callers must use a distinct request ID for each logical request.
///
/// Example after explicit pairing or authentication:
/// ```swift
/// let client = MobileLocalDirectRPCClient(admittedTransport: admitted.transport)
/// let events = await client.subscribe(to: ["workspace.updated"])
/// // Send the server's subscription RPC explicitly if events are wanted.
/// // On replacement: await client.disconnect(), then create a newly admitted client.
/// ```
public actor MobileLocalDirectRPCClient: MobileSyncing {
    /// Invalid caller input, rejected before transport use.
    public enum Failure: Error, Equatable, Sendable {
        /// Request must be a JSON object without legacy authorization fields.
        case invalidRequest
    }
    private let owner: MobileLocalDirectTransportOwner
    private let session: MobileCoreRPCSession
    private let requestTimeoutNanoseconds: UInt64
    private var disconnected = false
    private var disconnectTask: Task<Void, Never>?

    /// Takes ownership without connecting, sending bytes, or reading credentials.
    /// - Parameters:
    ///   - admittedTransport: Already route-proven and explicitly admitted byte stream.
    ///   - requestTimeoutNanoseconds: Default request deadline, thirty seconds.
    public init(admittedTransport: any CmxByteTransport, requestTimeoutNanoseconds: UInt64 = 30_000_000_000) {
        let owner = MobileLocalDirectTransportOwner(admittedTransport)
        self.owner = owner
        session = MobileCoreRPCSession(makeTransport: { try owner.claim() })
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }

    deinit {
        if let transport = owner.retire() { Task { await transport.close() } }
    }

    /// Retires this client permanently and drains its transport cleanup.
    public func disconnect() async {
        if let disconnectTask { await disconnectTask.value; return }
        disconnected = true
        let unclaimed = owner.retire()
        let session = session
        let task = Task {
            if let unclaimed { await unclaimed.close() }
            await session.tearDown(error: .connectionClosed)
            await session.waitForTransportDrain()
        }
        disconnectTask = task
        await task.value
    }

    /// Registers only a local event reader; the caller owns any server subscription RPC.
    /// - Parameter topics: Exact event topics to receive.
    /// - Returns: Stream whose termination removes its listener; closed after disconnect.
    public func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope> {
        guard !disconnected else { return AsyncStream { $0.finish() } }
        let subscription = await session.addEventListener(topics: topics)
        guard !disconnected else {
            await session.removeListener(id: subscription.id)
            return AsyncStream { $0.finish() }
        }
        return subscription.stream
    }

    /// Sends an RPC without auth augmentation or automatic retry.
    /// - Parameters:
    ///   - requestData: JSON request object with a method and optional unique string ID.
    ///   - timeoutNanoseconds: Optional override of the default deadline.
    /// - Returns: Raw JSON result, not the response envelope.
    /// - Throws: ``Failure/invalidRequest``, `MobileShellConnectionError`, or cancellation.
    public func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64? = nil) async throws -> Data {
        guard !disconnected else { throw MobileShellConnectionError.connectionClosed }
        try Task.checkCancellation()
        let deadline = RPCRequestDeadline(timeoutNanoseconds: timeoutNanoseconds ?? requestTimeoutNanoseconds)
        guard var object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let method = object["method"] as? String, !method.isEmpty else { throw Failure.invalidRequest }
        let forbidden: Set<String> = ["auth", "attach_token", "stack_access_token", "stack_refresh_token",
            "authorization", "access_token", "refresh_token", "token", "bearer"]
        guard forbidden.isDisjoint(with: object.keys) else { throw Failure.invalidRequest }
        let id: String
        if let supplied = object["id"] {
            guard let supplied = supplied as? String, !supplied.isEmpty else { throw Failure.invalidRequest }
            id = supplied
        } else {
            id = UUID().uuidString
            object["id"] = id
        }
        guard JSONSerialization.isValidJSONObject(object) else { throw Failure.invalidRequest }
        let payload = try JSONSerialization.data(withJSONObject: object)
        return try await session.send(payload: payload, requestID: id, deadlineUptimeNanoseconds: deadline.uptimeNanoseconds)
    }
}
