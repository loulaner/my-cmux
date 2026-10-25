// Compiled by test_mobile_artifact_policy_runtime.py, never linked into the app.
// Production snippets replace the tokens below verbatim. All dependencies are
// no-business-I/O recorders: allowed registry suffixes do NOT validate paths/TTL.
import Foundation

private struct Observation: Sendable {
    var scenario = ""
    var disabled = false
    var readers = 0
    var reads = 0
    var sends = 0
    var finishes = 0
    var closes = 0
    var snapshots = 0
    var resets: [UInt64] = []
    var stops: [UInt64] = []
    var priorities: [Int32] = []
}

// Every access to state is protected by lock; no closure suspends or escapes.
private final class Recorder: @unchecked Sendable {
    static let shared = Recorder()
    private let lock = NSLock()
    private var state = Observation()

    func update<T>(_ body: (inout Observation) -> T) -> T {
        lock.withLock { body(&state) }
    }

    func snapshot() -> Observation { update { $0 } }

    func reset(_ name: String) {
        update { $0 = Observation(scenario: name, disabled: name == "claim-disabled") }
    }
}

enum ManagedFileTransferPolicy {
    static var isDisabled: Bool { Recorder.shared.snapshot().disabled }
/*__OWNER__*/
}

struct TerminalController {
/*__RESULT_ENUM__*/
/*__HELPER__*/
}

struct CmxIrohResourceID: Equatable, Sendable { let value: String }
struct CmxIrohAdmittedPeer: Sendable {}
struct ChatArtifactLaneDescriptor: Sendable { let resourceID: String }
struct Identity: Equatable, Sendable { let size: Int64 }
protocol MobileHostIrohArtifactLaneHandling: Sendable {}

actor MobileHostIrohArtifactTransferRegistry {
    enum Error: Swift.Error { case invalidFile }
    struct Lease: Sendable {
        let canonicalPath = "in-memory-only"
        let identity: Identity
        let offset: UInt64 = 0
        let totalSize: Int64
    }
    private let isFileTransferDisabled: @Sendable () -> Bool
    private(set) var minted = 0
    private(set) var claims = 0
    private(set) var releases = 0

    init(isFileTransferDisabled: @escaping @Sendable () -> Bool = { ManagedFileTransferPolicy.isDisabled }) {
        self.isFileTransferDisabled = isFileTransferDisabled
    }
/*__CHECKER__*/
/*__ISSUE_PREFIX__*/
    func issuePlaceholder() {
        minted += 1
        return ChatArtifactLaneDescriptor(resourceID: "fixture")
    }
/*__CLAIM_PREFIX__*/
    func claimPlaceholder() {
        claims += 1
        let size: Int64 = Recorder.shared.update {
            if $0.scenario == "after-claim" { $0.disabled = true }
            return $0.scenario == "empty-before-finish" ? 0 : 65537
        }
        return Lease(identity: Identity(size: size), totalSize: size)
    }
    func release(_ lease: Lease) { releases += 1 }
}

final class MobileHostIrohArtifactDispatchReader: Sendable {
    init(path: String) throws { Recorder.shared.update { $0.readers += 1 } }

    func snapshot() throws -> Identity {
        Recorder.shared.update {
            $0.snapshots += 1
            if $0.scenario == "empty-before-finish" && $0.snapshots == 2 { $0.disabled = true }
            return Identity(size: $0.scenario == "empty-before-finish" ? 0 : 65537)
        }
    }

    func read(offset: UInt64, maximumByteCount: Int) async throws -> Data {
        let scenario = Recorder.shared.update {
            $0.reads += 1
            if $0.scenario == "during-read" { $0.disabled = true }
            return $0.scenario
        }
        if scenario == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        if scenario == "empty-read" { return Data() }
        return Data(repeating: 7, count: maximumByteCount)
    }

    func close() { Recorder.shared.update { $0.closes += 1 } }
}

struct SendStream: Sendable {
    func setPriority(_ priority: Int32) async throws {
        Recorder.shared.update { $0.priorities.append(priority) }
    }
    func send(_ data: Data) async throws {
        Recorder.shared.update {
            $0.sends += 1
            if $0.scenario == "after-first-send" { $0.disabled = true }
        }
    }
    func finish() async throws { Recorder.shared.update { $0.finishes += 1 } }
    func reset(errorCode: UInt64) async { Recorder.shared.update { $0.resets.append(errorCode) } }
}

struct ReceiveStream: Sendable {
    func stop(errorCode: UInt64) async { Recorder.shared.update { $0.stops.append(errorCode) } }
}

struct CmxIrohBidirectionalStream: Sendable {
    let sendStream = SendStream()
    let receiveStream = ReceiveStream()
}

/*__HANDLER__*/

@main
struct RuntimeChecks {
    struct Case: Sendable {
        let name: String
        let owned: Bool
        let readers: Int
        let reads: Int
        let sends: Int
        let finishes: Int
        let closes: Int
        let resets: [UInt64]
        let releases: Int
    }

    @MainActor
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let expected = URL(fileURLWithPath: env["CFFIXED_USER_HOME"]!).resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        precondition(home == expected, "Foundation home isolation failed")
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).resolvingSymlinksInPath()
        precondition(support.path.hasPrefix(expected.path + "/"), "Application Support escaped private home")
        let proof = support.appendingPathComponent("artifact-policy-proof-\(UUID()).log")
        try Data("private runtime fixture\n".utf8).write(to: proof)
        let contents = try String(contentsOf: proof, encoding: .utf8)
        precondition(contents == "private runtime fixture\n")
        print("ISOLATION home=\(home.path) support=\(support.path) proof=\(proof.path) temporaryDirectory=\(FileManager.default.temporaryDirectory.path)")

        var failures = 0
        var assertions = 0
        func check(_ condition: Bool, _ name: String) {
            assertions += 1
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let peer = CmxIrohAdmittedPeer()
        let id = CmxIrohResourceID(value: "fixture")
        let registry = MobileHostIrohArtifactTransferRegistry()
        Recorder.shared.update { $0.disabled = true }
        var issueRefused = false
        var claimRefused = false
        do { _ = try await registry.issue(canonicalPath: "never-accessed", peer: peer) }
        catch { issueRefused = ManagedFileTransferPolicy.isRefusal(error) }
        do { _ = try await registry.claim(resourceID: id, offset: 0, peer: peer) }
        catch { claimRefused = ManagedFileTransferPolicy.isRefusal(error) }
        let minted = await registry.minted
        let claims = await registry.claims
        check(issueRefused && minted == 0, "issue-prefix")
        check(claimRefused && claims == 0, "claim-prefix")
        for (index, disabled) in [false, true, false].enumerated() {
            Recorder.shared.update { $0.disabled = disabled }
            var refused = false
            do { try await registry.checkFileTransferPolicy() }
            catch { refused = ManagedFileTransferPolicy.isRefusal(error) }
            check(refused == disabled, "live-policy-\(index)")
        }
        Recorder.shared.update { $0.disabled = false }
        if case let .err(code, message, data) = TerminalController.mobileFileTransferDisabledResult {
            check(code == "file_transfer_disabled" && message == ManagedFileTransferPolicy.disabledMessage && data == nil, "occurred-refusal")
        } else {
            check(false, "occurred-refusal")
        }

        let cases = [
            Case(name: "claim-disabled", owned: false, readers: 0, reads: 0, sends: 0, finishes: 0, closes: 0, resets: [], releases: 0),
            Case(name: "after-claim", owned: true, readers: 0, reads: 0, sends: 0, finishes: 0, closes: 0, resets: [6], releases: 1),
            Case(name: "during-read", owned: true, readers: 1, reads: 1, sends: 0, finishes: 0, closes: 1, resets: [6], releases: 1),
            Case(name: "after-first-send", owned: true, readers: 1, reads: 1, sends: 1, finishes: 0, closes: 1, resets: [6], releases: 1),
            Case(name: "allowed", owned: true, readers: 1, reads: 2, sends: 2, finishes: 1, closes: 1, resets: [], releases: 1),
            Case(name: "cancel", owned: true, readers: 1, reads: 1, sends: 0, finishes: 0, closes: 1, resets: [0], releases: 1),
            Case(name: "empty-before-finish", owned: true, readers: 1, reads: 0, sends: 0, finishes: 0, closes: 1, resets: [6], releases: 1),
            Case(name: "empty-read", owned: true, readers: 1, reads: 1, sends: 0, finishes: 0, closes: 1, resets: [6], releases: 1)
        ]
        for test in cases {
            Recorder.shared.reset(test.name)
            let registry = MobileHostIrohArtifactTransferRegistry()
            let task = Task {
                await MobileHostIrohArtifactLaneHandler(registry: registry).handleArtifactLane(
                    resourceID: id, offset: 0, stream: CmxIrohBidirectionalStream(), peer: peer
                )
            }
            let owned = await task.value
            let releases = await registry.releases
            let state = Recorder.shared.snapshot()
            let expectedStops: [UInt64] = test.name == "claim-disabled" ? [] : test.name == "after-claim" ? [6] : [0] + test.resets
            let expectedPriorities: [Int32] = test.readers == 0 ? [] : [-10]
            let passed = owned == test.owned && state.readers == test.readers
                && state.reads == test.reads && state.sends == test.sends
                && state.finishes == test.finishes && state.closes == test.closes
                && state.resets == test.resets && state.stops == expectedStops
                && state.priorities == expectedPriorities && releases == test.releases
            print("TRACE \(test.name) reader=\(state.readers) read=\(state.reads) send=\(state.sends) "
                + "finish=\(state.finishes) close=\(state.closes) reset=\(state.resets) "
                + "stop=\(state.stops) release=\(releases)")
            check(passed, test.name)
        }
        print("SUMMARY assertions=\(assertions) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
