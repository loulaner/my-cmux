import Darwin
import Foundation
import Testing
@testable import CmuxMobileShell

struct MobileLocalDirectClientFileStoreTests {
    @Test func sandboxPlanStartsAtContainerNotSystemRoot() throws {
        let root = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/TEST")
        let plan = try MobileLocalDirectClientFileStore.directoryPlan(
            baseURL: root.appendingPathComponent("Library/Application Support/local-direct"), trustedContainerRoot: root)
        #expect(plan.anchor == root.path)
        #expect(plan.components == ["Library", "Application Support", "local-direct"])
        let aliasPlan = try MobileLocalDirectClientFileStore.directoryPlan(
            baseURL: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/TEST/Library/local-direct"), trustedContainerRoot: root)
        #expect(aliasPlan.anchor == root.path)
        #expect(aliasPlan.components == ["Library", "local-direct"])
    }

    @Test func sandboxPlanRejectsOutsideRootAndTraversal() throws {
        let root = URL(fileURLWithPath: "/private/var/mobile/container")
        for path in [root.path, root.path + "-collision/local-direct", "/private/var/other/local-direct",
                     root.path + "/../escape", root.path + "/Library/./local-direct"] {
            #expect(throws: (any Error).self) {
                try MobileLocalDirectClientFileStore.directoryPlan(baseURL: URL(fileURLWithPath: path), trustedContainerRoot: root)
            }
        }
    }

    @Test func portablePlanRetainsAbsoluteTraversal() throws {
        let plan = try MobileLocalDirectClientFileStore.directoryPlan(
            baseURL: URL(fileURLWithPath: "/var/tmp/task/local-direct"), trustedContainerRoot: nil)
        #expect(plan.anchor == "/")
        #expect(plan.components == ["private", "var", "tmp", "task", "local-direct"])
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func record() throws -> MobileLocalDirectClientRecord {
        try .init(host: "100.70.1.2", port: 49443, hostID: MobileDirectClientFixture.hostID,
            deviceID: MobileDirectClientFixture.deviceID, token: Data(repeating: 42, count: 32))
    }
    @Test func privateAtomicRoundTripAndCorruptionFailsClosed() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("local-direct")
        let store = MobileLocalDirectClientFileStore(baseURL: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let record = try record()
        try await store.save(record)
        let file = directory.appendingPathComponent("client-v1.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try await MobileLocalDirectClientFileStore(baseURL: directory).load() == record)
        try Data("corrupt".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(try Data(contentsOf: file) == Data("corrupt".utf8))
        try await store.forget()
        #expect(try await store.load() == nil)
    }
    @Test func symlinkAncestorCannotRedirectCapabilityWrite() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = MobileLocalDirectClientFileStore(baseURL: link.appendingPathComponent("local-direct"))
        let record = try record()
        await #expect(throws: (any Error).self) { try await store.save(record) }
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("local-direct/client-v1.json").path))
    }
}
