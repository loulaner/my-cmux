public import CMUXMobileCore
public import Foundation

/// Performs explicit approval or device-capability admission on an already VPN-gated stream.
///
/// This API never dials a network or approves a device by itself. The Mac owner
/// must supply the user's decision and a current-session check.
public struct CmxLocalDirectAdmission: Sendable {
    /// Safe on-wire and local admission failure.
    public enum Failure: Error, Sendable {
        /// Explicit refusal, or an invalid local request. Never retry automatically.
        case denied
        /// Transport failed or closed before a complete response arrived.
        case connectionLost
        /// The client exchange exceeded its bounded deadline.
        case timedOut
        /// A complete or oversized response violated the admission protocol.
        case invalidResponse
    }
    /// Successful server admission with preserved following RPC bytes.
    public struct Accepted: Sendable {
        /// Authenticated device metadata, not a VPN identity claim.
        public let peer: CmxLocalDevice
        /// The same live-gated transport with any coalesced RPC bytes replayed.
        public let transport: any CmxByteTransport
        /// Checks the current device record and owner epoch for every RPC.
        public let isAuthorized: @Sendable () async -> Bool
    }
    /// Successful client admission; a newly issued token must be saved before claiming persistence.
    public struct ClientAccepted: Sendable {
        /// Server-issued canonical device identifier.
        public let deviceID: String
        /// Present only after pairing, not after authentication.
        public let issuedToken: Data?
        /// The original stream with coalesced following bytes replayed.
        public let transport: any CmxByteTransport
    }
    private let store: CmxLocalDeviceCredentialStore
    private let approval: @Sendable (String) async -> Bool
    private let isCurrent: @Sendable () async -> Bool
    private let clock: any Clock<Duration>
    private let readTimeout: Duration
    private let approvalTimeout: Duration

    /// Creates admission with no network or persistence side effects.
    /// - Parameters:
    ///   - store: A successfully loaded scoped device store.
    ///   - approval: Actual user decision; false, cancellation and timeout deny pairing.
    ///   - isCurrent: Owner epoch and policy check.
    public init(store: CmxLocalDeviceCredentialStore, approval: @escaping @Sendable (String) async -> Bool,
                isCurrent: @escaping @Sendable () async -> Bool) {
        self.init(store: store, approval: approval, isCurrent: isCurrent, clock: ContinuousClock(),
                  readTimeout: .seconds(10), approvalTimeout: .seconds(60))
    }
    init(store: CmxLocalDeviceCredentialStore, approval: @escaping @Sendable (String) async -> Bool,
         isCurrent: @escaping @Sendable () async -> Bool, clock: any Clock<Duration>,
         readTimeout: Duration, approvalTimeout: Duration) {
        self.store = store; self.approval = approval; self.isCurrent = isCurrent
        self.clock = clock; self.readTimeout = readTimeout; self.approvalTimeout = approvalTimeout
    }

    /// Admits one already connected, route-gated transport and retains following RPC bytes.
    /// - Parameter transport: The listener's live-gated transport, never a raw product TCP stream.
    /// - Returns: Device context and the stream to pass into RPC.
    /// - Throws: ``Failure/denied`` after closing on every admission failure.
    public func accept(_ transport: any CmxByteTransport) async throws -> Accepted {
        do {
            guard await isCurrent(), !Task.isCancelled else { throw Failure.denied }
            let (data, remaining) = try await CmxLocalDirectDeadline<(Data, Data)>().run(
                timeout: readTimeout, clock: clock) { try await CmxLocalDirectWire.read(from: transport) }
            let request = try CmxLocalDirectWire.decode(data, response: false)
            let peer: CmxLocalDevice
            let reply: CmxLocalDirectWire
            if request.operation == "pair" {
                guard let name = request.displayName,
                      CmxLocalDeviceCredentialStore.validName(name) else { throw Failure.denied }
                let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let approved = try await CmxLocalDirectDeadline<Bool>().run(timeout: approvalTimeout, clock: clock) {
                    await approval(displayName)
                }
                guard approved, await isCurrent(), !Task.isCancelled else { throw Failure.denied }
                let issued = try await store.issueDevice(displayName: displayName)
                peer = issued.device
                reply = CmxLocalDirectWire(status: "paired", deviceID: peer.deviceID,
                                          token: issued.token.base64EncodedString())
            } else {
                guard let id = request.deviceID, CmxLocalDirectWire.validID(id) else { throw Failure.denied }
                peer = try await store.authenticate(deviceID: id, token: CmxLocalDirectWire.tokenBytes(request.token))
                reply = CmxLocalDirectWire(status: "authenticated", deviceID: peer.deviceID)
            }
            let authorized: @Sendable () async -> Bool = {
                guard await isCurrent() else { return false }
                return await store.devices().contains { $0.deviceID == peer.deviceID }
            }
            guard await authorized(), !Task.isCancelled else { throw Failure.denied }
            try await transport.send(reply.framed())
            guard await authorized(), !Task.isCancelled else { throw Failure.denied }
            return Accepted(peer: peer,
                transport: CmxLocalDirectBufferedTransport(base: transport, buffered: remaining, isCurrent: authorized),
                isAuthorized: authorized)
        } catch {
            if !Task.isCancelled { try? await transport.send(CmxLocalDirectWire(status: "denied").framed()) }
            await transport.close()
            throw Failure.denied
        }
    }

    /// Requests actual Mac approval over an established VPN-gated stream.
    /// - Parameters:
    ///   - displayName: Untrusted device label subject to the server's validation.
    ///   - transport: Already connected, route-proven transport; this function never dials.
    /// - Returns: Issued capability and the stream, without persisting client secrets.
    /// - Throws: A classified ``Failure`` or `CancellationError`, after closing the stream.
    public static func pair(displayName: String, transport: any CmxByteTransport) async throws -> ClientAccepted {
        guard CmxLocalDeviceCredentialStore.validName(displayName) else {
            await transport.close()
            if Task.isCancelled { throw CancellationError() }
            throw Failure.denied
        }
        return try await exchange(CmxLocalDirectWire(operation: "pair", displayName: displayName), transport: transport,
                           expectedStatus: "paired", timeout: .seconds(70))
    }

    /// Authenticates a remembered device over an established VPN-gated stream.
    /// - Parameters:
    ///   - deviceID: Previously issued device identifier.
    ///   - token: Exactly 32 capability bytes.
    ///   - transport: Already connected, route-proven transport.
    /// - Returns: Authenticated stream with any following bytes preserved.
    /// - Throws: A classified ``Failure`` or `CancellationError`, after closing the stream.
    public static func authenticate(deviceID: String, token: Data,
                                    transport: any CmxByteTransport) async throws -> ClientAccepted {
        guard token.count == 32, CmxLocalDirectWire.validID(deviceID) else {
            await transport.close()
            if Task.isCancelled { throw CancellationError() }
            throw Failure.denied
        }
        return try await exchange(CmxLocalDirectWire(operation: "authenticate", deviceID: deviceID,
            token: token.base64EncodedString()), transport: transport, expectedStatus: "authenticated", timeout: .seconds(10))
    }

    // Internal clock/deadline seam; production callers use the public pair/authenticate bounds.
    static func exchange(_ request: CmxLocalDirectWire, transport: any CmxByteTransport,
                         expectedStatus: String, timeout: Duration,
                         clock: any Clock<Duration> = ContinuousClock()) async throws -> ClientAccepted {
        do {
            try Task.checkCancellation()
            let frame: Data
            do { frame = try request.framed() } catch { throw Failure.denied }
            let (data, remaining): (Data, Data)
            do {
                (data, remaining) = try await CmxLocalDirectDeadline<(Data, Data)>().run(timeout: timeout, clock: clock) {
                    do { try await transport.send(frame) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        throw Failure.connectionLost
                    }
                    return try await CmxLocalDirectWire.read(from: transport)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if error is CmxLocalDirectDeadline<(Data, Data)>.Failure { throw Failure.timedOut }
                if case CmxLocalDirectWire.Failure.protocolViolation = error { throw Failure.invalidResponse }
                throw Failure.connectionLost
            }
            let response: CmxLocalDirectWire
            do { response = try CmxLocalDirectWire.decode(data, response: true) }
            catch { throw Failure.invalidResponse }
            if response.status == "denied" { throw Failure.denied }
            guard response.status == expectedStatus, let id = response.deviceID, CmxLocalDirectWire.validID(id),
                  request.deviceID == nil || request.deviceID == id else { throw Failure.invalidResponse }
            let token: Data?
            do { token = expectedStatus == "paired" ? try CmxLocalDirectWire.tokenBytes(response.token) : nil }
            catch { throw Failure.invalidResponse }
            try Task.checkCancellation()
            return ClientAccepted(deviceID: id, issuedToken: token,
                transport: CmxLocalDirectBufferedTransport(base: transport, buffered: remaining, isCurrent: { true }))
        } catch {
            await transport.close()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
