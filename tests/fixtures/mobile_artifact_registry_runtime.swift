// Template for test_mobile_artifact_registry_runtime.py; not an app target.
// Registry/identity/value types and refusal bodies are inserted verbatim.
// Only the peer and injected policy/clock/ID generator are test doubles.
import Darwin
import Foundation

/*__RESOURCE_ID_ERROR__*/
/*__RESOURCE_ID__*/
/*__DESCRIPTOR__*/
/*__ISSUE_FAILURE__*/
/*__REGISTRY__*/
/*__IDENTITY__*/

enum ManagedFileTransferPolicy {
    static var isDisabled: Bool {
        preconditionFailure("Tests must inject policy; never access real managed preferences")
    }
/*__OWNER__*/
}

struct CmxIrohAdmittedPeer: Equatable, Sendable {
    let testID: String
}

// All mutable state is lock protected, with no suspension inside the lock.
final class RegistryInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var disabledValue = false
    private var clockValue = Date(timeIntervalSince1970: 1000)
    private var idCount = 0
    private let namespace = UUID().uuidString

    var disabled: Bool {
        get { lock.withLock { disabledValue } }
        set { lock.withLock { disabledValue = newValue } }
    }
    var date: Date {
        get { lock.withLock { clockValue } }
        set { lock.withLock { clockValue = newValue } }
    }
    var minted: Int { lock.withLock { idCount } }
    func mint() throws -> CmxIrohResourceID {
        try lock.withLock {
            idCount += 1
            return try CmxIrohResourceID("artifact:\(namespace)-\(idCount)")
        }
    }
    func registry() -> MobileHostIrohArtifactTransferRegistry {
        MobileHostIrohArtifactTransferRegistry(
            timeToLive: 30, now: { self.date }, resourceID: { try self.mint() },
            isFileTransferDisabled: { self.disabled }
        )
    }
}

@MainActor
final class Assertions {
    var count = 0
    var failures = 0
    func check(_ value: Bool, _ label: String) {
        count += 1
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL") \(label)")
    }
    func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body() }
        catch {
            print("UNEXPECTED \(name): \(error)")
            check(false, "\(name)-unexpected-error")
        }
    }
}

@main
struct RegistryChecks {
    typealias Registry = MobileHostIrohArtifactTransferRegistry

    // Unexpected success must release immediately, including in mutant runs.
    static func claimError(
        _ registry: Registry, id: CmxIrohResourceID, offset: UInt64 = 0, peer: CmxIrohAdmittedPeer
    ) async -> Error? {
        do {
            let lease = try await registry.claim(resourceID: id, offset: offset, peer: peer)
            await registry.release(lease)
            return nil
        } catch { return error }
    }

    @MainActor
    static func exercise(home: URL, checks: Assertions) async throws {
        let manager = FileManager.default
        let root = home.appendingPathComponent("registry-fixtures-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try manager.removeItem(at: root) }
            catch { checks.check(false, "fixture-cleanup") }
        }
        let file = root.appendingPathComponent("six-bytes.dat")
        let missing = root.appendingPathComponent("missing.dat")
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try Data("abcdef".utf8).write(to: file)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        print("FIXTURES root=\(root.path) syntheticFile=\(file.path) bytes=6")
        let peer = CmxIrohAdmittedPeer(testID: "peer-a")
        let other = CmxIrohAdmittedPeer(testID: "peer-b")

        await checks.run("priority") {
            let inputs = RegistryInputs()
            let registry = inputs.registry()
            inputs.disabled = true
            var issueError: Error?
            do { _ = try await registry.issue(canonicalPath: missing.path, peer: peer) }
            catch { issueError = error }
            checks.check(issueError.map(ManagedFileTransferPolicy.isRefusal) == true && inputs.minted == 0, "issue-priority")
            let unknown = try CmxIrohResourceID("artifact:unknown")
            let error = await claimError(registry, id: unknown, peer: peer)
            checks.check(error.map(ManagedFileTransferPolicy.isRefusal) == true, "claim-priority")
            for (index, disabled) in [false, true, false].enumerated() {
                inputs.disabled = disabled
                var refused = false
                do { try await registry.checkFileTransferPolicy() }
                catch { refused = ManagedFileTransferPolicy.isRefusal(error) }
                checks.check(refused == disabled, "live-policy-\(index)")
            }
        }

        await checks.run("descriptor") {
            let inputs = RegistryInputs()
            let registry = inputs.registry()
            let descriptor = try await registry.issue(canonicalPath: file.path, peer: peer)
            checks.check(descriptor.totalSize == 6 && descriptor.expiresAt == inputs.date.addingTimeInterval(30)
                && inputs.minted == 1, "descriptor-size-expiry")
            let id = try CmxIrohResourceID(descriptor.resourceID)
            let identity = try MobileHostIrohArtifactFileIdentity.snapshot(path: file.path)
            let lease = try await registry.claim(resourceID: id, offset: 2, peer: peer)
            checks.check(lease.canonicalPath == file.resolvingSymlinksInPath().path && lease.offset == 2
                && lease.totalSize == 6 && lease.resourceID == id && lease.identity == identity, "lease-real-identity-offset")
            await registry.release(lease)
        }

        await checks.run("budget") {
            let inputs = RegistryInputs()
            let registry = inputs.registry()
            let descriptor = try await registry.issue(canonicalPath: file.path, peer: peer)
            let id = try CmxIrohResourceID(descriptor.resourceID)
            inputs.disabled = true
            var refusals = 0
            for _ in 0..<10 {
                let error = await claimError(registry, id: id, peer: peer)
                if error.map(ManagedFileTransferPolicy.isRefusal) == true { refusals += 1 }
            }
            checks.check(refusals == 10, "pause-ten-refusals")
            inputs.disabled = false
            let wrongPeer = await claimError(registry, id: id, peer: other)
            checks.check(wrongPeer as? Registry.Error == .peerMismatch, "wrong-peer")
            let wrongOffset = await claimError(registry, id: id, offset: 7, peer: peer)
            checks.check(wrongOffset as? Registry.Error == .invalidOffset, "invalid-offset")
            var completed = 0
            for index in 1...8 {
                do {
                    let lease = try await registry.claim(resourceID: id, offset: 0, peer: peer)
                    completed += 1
                    await registry.release(lease)
                } catch { print("BUDGET claim=\(index) error=\(error)") }
            }
            print("BUDGET completed=\(completed) expected=8")
            checks.check(completed == 8, "budget-eight")
            let ninth = await claimError(registry, id: id, peer: peer)
            checks.check(ninth as? Registry.Error == .resumeLimitExceeded, "budget-ninth-refused")
        }

        await leasesAndMetadata(file: file, missing: missing, directory: directory, peer: peer, checks: checks)
    }

    @MainActor
    static func leasesAndMetadata(
        file: URL, missing: URL, directory: URL, peer: CmxIrohAdmittedPeer, checks: Assertions
    ) async {
        await checks.run("lease") {
            let inputs = RegistryInputs()
            let registry = inputs.registry()
            let descriptor = try await registry.issue(canonicalPath: file.path, peer: peer)
            let id = try CmxIrohResourceID(descriptor.resourceID)
            let lease = try await registry.claim(resourceID: id, offset: 0, peer: peer)
            let active = await claimError(registry, id: id, peer: peer)
            checks.check(active as? Registry.Error == .alreadyInUse, "active-lease-serial")
            let wrong = Registry.Lease(
                id: UUID(), resourceID: lease.resourceID, canonicalPath: lease.canonicalPath,
                identity: lease.identity, offset: lease.offset, totalSize: lease.totalSize
            )
            await registry.release(wrong)
            let stillActive = await claimError(registry, id: id, peer: peer)
            checks.check(stillActive as? Registry.Error == .alreadyInUse, "wrong-release-still-active")
            await registry.release(lease)
            let resumed = try await registry.claim(resourceID: id, offset: 6, peer: peer)
            checks.check(resumed.id != lease.id && resumed.offset == 6, "correct-release-resumes")
            await registry.release(resumed)
        }

        await checks.run("expiry") {
            let inputs = RegistryInputs()
            let registry = inputs.registry()
            let descriptor = try await registry.issue(canonicalPath: file.path, peer: peer)
            let id = try CmxIrohResourceID(descriptor.resourceID)
            inputs.disabled = true
            inputs.date = descriptor.expiresAt.addingTimeInterval(1)
            let paused = await claimError(registry, id: id, peer: peer)
            checks.check(paused.map(ManagedFileTransferPolicy.isRefusal) == true, "expired-while-disabled")
            inputs.disabled = false
            let expired = await claimError(registry, id: id, peer: peer)
            checks.check(expired as? Registry.Error == .expired, "reallow-still-expired")
            let independent = RegistryInputs().registry()
            let unknown = await claimError(independent, id: id, peer: peer)
            checks.check(unknown as? Registry.Error == .unknownResource, "registry-isolation")
        }

        await checks.run("capacity") {
            let inputs = RegistryInputs()
            let registry = inputs.registry()
            var ids = Set<String>()
            for _ in 0..<128 {
                let descriptor = try await registry.issue(canonicalPath: file.path, peer: peer)
                ids.insert(descriptor.resourceID)
            }
            checks.check(ids.count == 128 && inputs.minted == 128, "capacity-128")
            var overflow: Error?
            do { _ = try await registry.issue(canonicalPath: file.path, peer: peer) }
            catch { overflow = error }
            checks.check(overflow as? Registry.Error == .capacityExceeded && inputs.minted == 128, "capacity-overflow")
            inputs.date = inputs.date.addingTimeInterval(31)
            let replacement = try await registry.issue(canonicalPath: file.path, peer: peer)
            checks.check(!ids.contains(replacement.resourceID) && inputs.minted == 129
                && replacement.expiresAt == inputs.date.addingTimeInterval(30), "capacity-expiry-prune")
        }

        await checks.run("identity") {
            let identity = try MobileHostIrohArtifactFileIdentity.snapshot(path: file.path)
            checks.check(identity.size == 6, "identity-regular-file")
            var directoryError: Error?
            do { _ = try MobileHostIrohArtifactFileIdentity.snapshot(path: directory.path) }
            catch { directoryError = error }
            checks.check(directoryError as? Registry.Error == .notRegularFile, "identity-directory-refused")
            var missingError: Error?
            do { _ = try MobileHostIrohArtifactFileIdentity.snapshot(path: missing.path) }
            catch { missingError = error }
            checks.check(missingError as? Registry.Error == .fileNotFound, "identity-missing-refused")
        }
    }

    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let expected = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!).resolvingSymlinksInPath()
        let home = manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        precondition(home == expected, "Foundation home isolation failed")
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .resolvingSymlinksInPath()
        precondition(support.path.hasPrefix(home.path + "/"), "Application Support escaped private home")
        let proof = support.appendingPathComponent("registry-proof-\(UUID()).log")
        try Data("private registry fixture\n".utf8).write(to: proof)
        let readBack = try String(contentsOf: proof, encoding: .utf8)
        precondition(readBack == "private registry fixture\n")
        print("ISOLATION home=\(home.path) support=\(support.path) proof=\(proof.path) temporaryDirectory=\(manager.temporaryDirectory.path)")
        let checks = Assertions()
        try await exercise(home: home, checks: checks)
        print("SUMMARY assertions=\(checks.count) failures=\(checks.failures)")
        exit(checks.failures == 0 ? 0 : 1)
    }
}
