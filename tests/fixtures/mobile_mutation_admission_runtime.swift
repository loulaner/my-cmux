import Foundation
import Darwin

// Controlled boundary types only. No authentication cryptography, Iroh, transport or app runtime.
struct CmxLocalDevice: Equatable, Sendable { let deviceID: String }
struct CmxIrohAdmittedPeer: Equatable, Sendable { let bindingID: String }
struct ChatArtifactLaneDescriptor: Equatable, Sendable { let path: String }
actor MobileHostIrohArtifactTransferRegistry {
    enum Error: Swift.Error { case unavailable }
    func issue(canonicalPath: String, peer: CmxIrohAdmittedPeer) throws -> ChatArtifactLaneDescriptor { .init(path: canonicalPath) }
}
struct CmxIrohActiveBindingConnectionQuota {
    func allowsAdmission<S: Sequence>(for id: String, activeBindingIDs: S) -> Bool where S.Element == String { true }
}
extension Notification.Name { static let mobileHostStatusDidChange = Notification.Name("fixture.mutation-admission") }

/*__AUTHORIZATION__*/
/*__CONTEXT__*/
/*__REGISTRY__*/

// Only the actor's surrounding state and lifecycle are controlled; the new method is verbatim production.
actor MobileHostConnection {
    private var isClosed = false
    private let isAuthorizationCurrent: @Sendable () async -> Bool
    init(authorization: @escaping @Sendable () async -> Bool) { isAuthorizationCurrent = authorization }
    func close() { isClosed = true }
    func closed() -> Bool { isClosed }
    /*__CONNECTION_METHOD__*/
}

private actor Gate {
    private var entered = false
    private var released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        let waiters = arrival; arrival.removeAll(); for waiter in waiters { waiter.resume() }
        if !released { await withCheckedContinuation { release = $0 } }
    }
    func wait() async {
        if !entered { await withCheckedContinuation { arrival.append($0) } }
    }
    func open() { released = true; release?.resume(); release = nil }
}
private actor Answers {
    private(set) var calls = 0
    var value = true
    func answer() -> Bool { calls += 1; return value }
    func set(_ value: Bool) { self.value = value }
}

@main
struct MutationAdmissionRuntime {
    @MainActor private static var assertions = 0
    @MainActor private static var failures = 0
    @MainActor private static func check(_ value: Bool, _ message: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL \(message)") }
    }
    private static let direct = MobileHostConnectionAuthorizationContext.localDirect(.init(deviceID: "fixture-device"))
    private static let peer = MobileHostConnectionAuthorizationContext.irohAdmission(.init(bindingID: "fixture-binding"))

    @MainActor static func main() async throws {
        await contexts()
        await connections()
        await registryBasics()
        for operation in ["remove", "removeAll", "removeLocal", "replace", "replaceWrongType"] { await registryRace(operation) }
        let fm = FileManager.default
        print("Foundation home=\(fm.homeDirectoryForCurrentUser.path) support=\(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path) temporaryDirectory=\(fm.temporaryDirectory.path)")
        print("ASSERTIONS \(assertions) FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func contexts() async {
        let id = UUID(), artifacts = MobileHostIrohArtifactTransferRegistry(), answers = Answers()
        let legacy = MobileHostRPCExecutionContext(connectionID: id, authorization: direct, artifactTransfers: artifacts)
        check(legacy.connectionID == id && legacy.authorization == direct && legacy.artifactTransfers === artifacts, "three-argument compatibility")
        check(!(await legacy.validateLocalDirectMutationAdmission()), "missing validator fails closed")
        for authorization in [.stackBearer, peer] {
            let context = MobileHostRPCExecutionContext(connectionID: id, authorization: authorization, artifactTransfers: artifacts,
                mutationAdmissionValidator: { await answers.answer() })
            check(!(await context.validateLocalDirectMutationAdmission()), "nonDirect rejects even true callback")
        }
        check(await answers.calls == 0, "nonDirect never calls validator")
        let context = MobileHostRPCExecutionContext(connectionID: id, authorization: direct, artifactTransfers: nil,
            mutationAdmissionValidator: { await answers.answer() })
        check(await context.validateLocalDirectMutationAdmission(), "fresh true context")
        await answers.set(false)
        check(!(await context.validateLocalDirectMutationAdmission()), "fresh false, not cached")
        await answers.set(true)
        check(await context.validateLocalDirectMutationAdmission(), "fresh true again")
        check(await answers.calls == 3, "one callback per permitted invocation")
        let barrier = Gate()
        let cancelled = Task { await barrier.pause(); return await context.validateLocalDirectMutationAdmission() }
        await barrier.wait(); cancelled.cancel(); await barrier.open()
        check(!(await cancelled.value), "pre-cancelled context false")
        check(await answers.calls == 3, "pre-cancelled context zero callback")
        let gate = Gate()
        let suspended = MobileHostRPCExecutionContext(connectionID: id, authorization: direct, artifactTransfers: nil,
            mutationAdmissionValidator: { _ = await answers.answer(); await gate.pause(); return true })
        let pending = Task { await suspended.validateLocalDirectMutationAdmission() }
        await gate.wait(); pending.cancel(); await gate.open()
        check(!(await pending.value), "context cancellation during await")
        check(await answers.calls == 4, "suspended callback exactly once")
        // Artifact method is the real unchanged implementation, collaborators are controlled.
        let artifactContext = MobileHostRPCExecutionContext(connectionID: id, authorization: peer, artifactTransfers: artifacts)
        do { let lane = try await artifactContext.issueArtifactTransfer(canonicalPath: "fixture-relative"); check(lane.path == "fixture-relative", "artifact delegation retained") }
        catch { check(false, "artifact delegation unexpected error") }
        do { _ = try await legacy.issueArtifactTransfer(canonicalPath: "fixture-relative"); check(false, "Direct cannot use Iroh artifact lane") }
        catch MobileHostIrohArtifactTransferRegistry.Error.unavailable { check(true, "artifact refusal retained") }
        catch { check(false, "wrong artifact error") }
    }

    @MainActor private static func connections() async {
        let answers = Answers(), connection = MobileHostConnection(authorization: { await answers.answer() })
        check(await connection.isMutationAdmissionCurrent(), "open connection true")
        check(await answers.calls == 1, "open exactly once")
        await answers.set(false)
        check(!(await connection.isMutationAdmissionCurrent()), "revoked connection false")
        check(await answers.calls == 2, "false auth once")
        await connection.close()
        check(!(await connection.isMutationAdmissionCurrent()), "closed entry rejected")
        check(await answers.calls == 2, "closed entry zero auth")
        let open = MobileHostConnection(authorization: { await answers.answer() }), barrier = Gate()
        let cancelled = Task { await barrier.pause(); return await open.isMutationAdmissionCurrent() }
        await barrier.wait(); cancelled.cancel(); await barrier.open()
        check(!(await cancelled.value), "cancelled connection entry false")
        check(await answers.calls == 2, "cancelled connection entry zero auth")
        for close in [true, false] {
            let gate = Gate(), counter = Answers()
            let active = MobileHostConnection(authorization: { _ = await counter.answer(); await gate.pause(); return true })
            let pending = Task { await active.isMutationAdmissionCurrent() }
            await gate.wait()
            if close { await active.close() } else { pending.cancel() }
            await gate.open()
            check(!(await pending.value), "post-await closed/cancelled false")
            check(await counter.calls == 1, "suspended auth once")
        }
    }

    @MainActor private static func registryBasics() async {
        let registry = MobileHostConnectionRegistry(), id = UUID(), answers = Answers()
        let connection = MobileHostConnection(authorization: { await answers.answer() })
        check(!(await registry.isLocalDirectMutationAdmissionCurrent(id: id)), "missing entry false")
        for authorization in [.stackBearer, peer] {
            check(registry.insert(connection, id: id, authorization: authorization, limit: 10), "insert nonDirect")
            check(!(await registry.isLocalDirectMutationAdmissionCurrent(id: id)), "registry validates actual entry type")
        }
        check(await answers.calls == 0, "wrong entry type zero auth")
        check(registry.insert(connection, id: id, authorization: direct, limit: 10), "insert Direct")
        check(await registry.isLocalDirectMutationAdmissionCurrent(id: id), "current Direct accepted")
        await answers.set(false)
        check(!(await registry.isLocalDirectMutationAdmissionCurrent(id: id)), "current authorization revoked")
        check(await answers.calls == 2, "registry invokes fresh auth")
        await connection.close()
        check(!(await registry.isLocalDirectMutationAdmissionCurrent(id: id)), "closed registry connection")
        check(await answers.calls == 2, "closed registry entry zero auth")
        let gate = Gate(), counter = Answers()
        let live = MobileHostConnection(authorization: { _ = await counter.answer(); await gate.pause(); return true })
        check(registry.insert(live, id: id, authorization: direct, limit: 10), "insert live connection")
        let pending = Task { await registry.isLocalDirectMutationAdmissionCurrent(id: id) }
        await gate.wait(); await live.close(); await gate.open()
        check(!(await pending.value), "registry close during auth")
        check(registry.connection(id: id) === live, "query never removes entries")
        let cancelGate = Gate(), fresh = MobileHostConnection(authorization: { await cancelGate.pause(); return true })
        check(registry.insert(fresh, id: id, authorization: direct, limit: 10), "insert cancellable connection")
        let cancel = Task { await registry.isLocalDirectMutationAdmissionCurrent(id: id) }
        await cancelGate.wait(); cancel.cancel(); await cancelGate.open()
        check(!(await cancel.value), "registry cancellation during auth")
        check(!(await fresh.closed()), "query cancellation never closes connection")
    }

    @MainActor private static func registryRace(_ operation: String) async {
        let registry = MobileHostConnectionRegistry(), id = UUID(), gate = Gate(), answers = Answers()
        let original = MobileHostConnection(authorization: { _ = await answers.answer(); await gate.pause(); return true })
        let replacement = MobileHostConnection(authorization: { true })
        check(registry.insert(original, id: id, authorization: direct, limit: 10), "race insert original")
        let pending = Task { await registry.isLocalDirectMutationAdmissionCurrent(id: id) }
        await gate.wait()
        // Synchronous real registry mutations while auth is suspended also prove the lock is not held across await.
        switch operation {
        case "remove": registry.remove(id: id)
        case "removeAll": check(registry.removeAll().count == 1, "removeAll selection")
        case "removeLocal": check(registry.removeLocalDirectConnections(deviceID: "fixture-device").count == 1, "removeLocal selection")
        default:
            check(registry.insert(replacement, id: id, authorization: operation == "replace" ? direct : .stackBearer, limit: 10), "same UUID replacement")
        }
        await gate.open()
        check(!(await pending.value), "stale registry query rejected: \(operation)")
        check(await answers.calls == 1, "race authorizes original once")
        let originalClosed = await original.closed(), replacementClosed = await replacement.closed()
        check(!originalClosed && !replacementClosed, "query never closes either object")
        if operation.hasPrefix("replace") {
            check(registry.connection(id: id) === replacement && registry.count == 1, "late query preserves new entry")
            check(await registry.isLocalDirectMutationAdmissionCurrent(id: id) == (operation == "replace"), "replacement own authorization query")
        } else { check(registry.connection(id: id) == nil && registry.count == 0, "query does not recreate removed entry") }
    }
}
