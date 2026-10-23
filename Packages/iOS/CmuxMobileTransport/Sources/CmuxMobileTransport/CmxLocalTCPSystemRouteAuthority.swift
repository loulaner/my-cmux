import Foundation
@preconcurrency import Network
import os

/// Monitors one explicitly pinned VPN interface; losing evidence permanently revokes this generation.
actor CmxLocalTCPSystemRouteAuthority: CmxLocalTCPRouteAuthorizing, CmxLocalTCPClientRouteAuthorizing {
    private enum Role { case server(String), client(String, Int) }
    private let monitor = NWPathMonitor()
    private let clock: any Clock<Duration>
    private let deadline: Duration
    // Carve-out: synchronously stamp callbacks before actor hops can reorder them.
    private let sequence = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var latest: UInt64 = 0
    private var role: Role?
    private var proof: CmxLocalTCPRouteProof?
    private var requiredInterface: NWInterface?
    private var invalidated: (@Sendable () async -> Void)?
    private var waiter: CheckedContinuation<NWInterface?, any Error>?
    private var timer: Task<Void, Never>?
    private var revoked = false

    init(clock: any Clock<Duration> = ContinuousClock(), deadline: Duration = .seconds(10)) {
        self.clock = clock
        self.deadline = deadline
    }

    func prepare(address: String, invalidated: @escaping @Sendable () async -> Void) async throws -> NWInterface? {
        try await prepare(role: .server(address), invalidated: invalidated)
    }

    func prepareClient(peerAddress: String, peerPort: Int,
                       invalidated: @escaping @Sendable () async -> Void) async throws -> CmxLocalTCPClientRouteBinding {
        guard CmxLocalTCPListenerConfiguration.isAllowedAddress(peerAddress), (1...65535).contains(peerPort) else {
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
        let interface = try await prepare(role: .client(peerAddress, peerPort), invalidated: invalidated)
        guard !revoked, let proof, let interface else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        return .init(localAddress: proof.localIPv4, requiredInterface: interface)
    }

    private func prepare(role: Role, invalidated: @escaping @Sendable () async -> Void) async throws -> NWInterface? {
        guard !revoked, self.role == nil else { throw CmxLocalTCPRouteProof.Failure.unavailable }
        self.role = role
        self.invalidated = invalidated
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                let sequence = sequence
                monitor.pathUpdateHandler = { [weak self] path in
                    let number = sequence.withLock { $0 &+= 1; return $0 }
                    let snapshot = Self.snapshot(path, sequence: number)
                    Task { await self?.ingest(path, snapshot: snapshot) }
                }
                timer = Task { [weak self, clock, deadline] in
                    do { try await clock.sleep(for: deadline); await self?.expire() } catch {}
                }
                monitor.start(queue: DispatchQueue(label: "dev.cmux.local-tcp-route"))
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    private func expire() async { await revoke(notify: true) }

    private func ingest(_ path: NWPath, snapshot: CmxTailscaleAuthoritySnapshot) async {
        guard !revoked, snapshot.generation > latest, let role else { return }
        latest = snapshot.generation
        do {
            let candidate: CmxLocalTCPRouteProof
            switch role {
            case let .server(address): candidate = try .prepare(address: address, snapshot: snapshot)
            case let .client(peer, _): candidate = try .prepareClient(peerAddress: peer, snapshot: snapshot)
            }
            if let proof {
                guard proof == candidate else { throw CmxLocalTCPRouteProof.Failure.unavailable }
            } else {
                guard let interface = path.availableInterfaces.first(where: {
                    $0.name == candidate.interface.name && $0.index == candidate.interface.index
                }) else { throw CmxLocalTCPRouteProof.Failure.unavailable }
                proof = candidate
                requiredInterface = interface
                timer?.cancel()
                timer = nil
                let continuation = waiter
                waiter = nil
                continuation?.resume(returning: interface)
            }
        } catch { await revoke(notify: true) }
    }

    func validate(path: NWPath?, port: Int) async throws {
        // Fresh synchronous captures close the gap before queued monitor callbacks arrive.
        let number = sequence.withLock { $0 &+= 1; return $0 }
        let current = monitor.currentPath
        let snapshot = Self.snapshot(current, sequence: number)
        await ingest(current, snapshot: snapshot)
        guard case .server = role, !revoked, let proof, let requiredInterface, let path,
              case let .hostPort(.ipv4(local), localPort) = path.localEndpoint,
              case let .hostPort(.ipv4(remote), _) = path.remoteEndpoint else {
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
        try proof.validateConnection(isSatisfied: path.status == .satisfied,
            interfaces: Set(path.availableInterfaces.map { .init(name: $0.name, index: $0.index) }),
            usesRequiredType: path.usesInterfaceType(requiredInterface.type),
            localAddress: CmxTailscaleIPAddress(family: .ipv4, bytes: local.rawValue),
            localPort: Int(localPort.rawValue), expectedPort: port,
            remoteAddress: CmxTailscaleIPAddress(family: .ipv4, bytes: remote.rawValue),
            selfAddresses: Set(snapshot.systemInterfaces.flatMap(\.addresses)))
    }

    func validateClient(path: NWPath?) async throws {
        let number = sequence.withLock { $0 &+= 1; return $0 }
        let current = monitor.currentPath
        let snapshot = Self.snapshot(current, sequence: number)
        await ingest(current, snapshot: snapshot)
        do {
            guard case let .client(peer, port) = role, !revoked, let proof, let requiredInterface, let path,
                  case let .hostPort(.ipv4(local), localPort) = path.localEndpoint,
                  case let .hostPort(.ipv4(remote), remotePort) = path.remoteEndpoint else {
                throw CmxLocalTCPRouteProof.Failure.unavailable
            }
            try proof.validateClientConnection(isSatisfied: path.status == .satisfied,
                interfaces: Set(path.availableInterfaces.map { .init(name: $0.name, index: $0.index) }),
                usesRequiredType: path.usesInterfaceType(requiredInterface.type),
                localAddress: CmxTailscaleIPAddress(family: .ipv4, bytes: local.rawValue), localPort: Int(localPort.rawValue),
                remoteAddress: CmxTailscaleIPAddress(family: .ipv4, bytes: remote.rawValue), remotePort: Int(remotePort.rawValue),
                peerAddress: peer, peerPort: port, snapshot: snapshot)
        } catch {
            await revoke(notify: true)
            throw CmxLocalTCPRouteProof.Failure.unavailable
        }
    }

    func stop() async { await revoke(notify: false) }

    private func revoke(notify: Bool) async {
        guard !revoked else { return }
        revoked = true
        proof = nil
        requiredInterface = nil
        monitor.cancel()
        timer?.cancel()
        timer = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(throwing: CmxLocalTCPRouteProof.Failure.unavailable)
        let callback = invalidated
        invalidated = nil
        // Clear ownership before the callback, which may call stop again.
        if notify { await callback?() }
    }

    private nonisolated static func snapshot(_ path: NWPath, sequence: UInt64) -> CmxTailscaleAuthoritySnapshot {
        .init(generation: sequence, pathSatisfied: path.status == .satisfied,
              availableInterfaces: Set(path.availableInterfaces.map { .init(name: $0.name, index: $0.index) }),
              systemInterfaces: CmxSystemInterfaceSnapshotReader().read())
    }
}
