import AppKit
import CmuxCloud
import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Shared machine verbs, explicit fleet reads and entry renderers remain
/// independent of the retired top-level Cloud menus.
@MainActor
@Suite("Cloud menus")
struct CloudMenuContentTests {
    @Test("Machine submenu offers only verbs the machine honors")
    func machineVerbs() throws {
        let recorder = Recorder()
        var limited = Self.machine("plain")
        limited.capabilities.snapshot = false
        limited.capabilities.fork = false
        let plainIDs = recorder.machine.submenuEntries(limited).compactMap(Self.actionID)
        #expect(plainIDs == ["machine.plain.openShell", "machine.plain.newWorkspace", "machine.plain.openFullClient",
                             "machine.plain.rename", "machine.plain.status", "machine.plain.delete"])

        // Missing or false capability metadata must hide recovery in every
        // menu. An explicit server opt-in routes to the shared CLI action.
        limited.capabilities.restart = true
        let recoveryEntries = recorder.machine.submenuEntries(limited)
        try Self.perform("machine.plain.restart", in: recoveryEntries)
        #expect(recorder.log == ["run:plain:vm restart"])
        recorder.log.removeAll()
        limited.capabilities.restart = false
        #expect(!recorder.machine.submenuEntries(limited).contains { $0.id == "machine.plain.restart" })

        // Freestyle: no native fork, but the backend forks through snapshot + create.
        var snapshotForked = Self.machine("snap")
        snapshotForked.capabilities = VMCapabilities(snapshot: true, restore: true, fork: false)
        #expect(recorder.machine.submenuEntries(snapshotForked).contains { $0.id == "machine.snap.fork" })

        var desktop = Self.machine("desk", isDesktop: true)
        desktop.privateAddress = "100.64.0.9"
        let desktopEntries = recorder.machine.submenuEntries(desktop)
        #expect(desktopEntries.contains { $0.id == "machine.desk.openDesktop" })
        try Self.perform("machine.desk.copyIP", in: desktopEntries)
        try Self.perform("machine.desk.checkpoint", in: desktopEntries)
        try Self.perform("machine.desk.newWorkspace", in: desktopEntries)
        // Fork goes to the shared create coordinator (pending row), never a raw CLI launch.
        try Self.perform("machine.desk.fork", in: desktopEntries)
        #expect(recorder.log == ["copy:100.64.0.9", "run:desk:vm snapshot", "newWorkspace:desk", "fork:desk"])

        var expired = Self.machine("locked")
        expired.freeAccess = .expired
        let openIDs = recorder.machine.openEntries(expired).compactMap(Self.actionID)
        #expect(openIDs == ["machine.locked.upgrade"])
        #expect(CloudMenuTone(expired) == .locked)
    }

    @Test("Delete routes the current machine display name, including after a rename")
    func deleteMenuUsesCurrentDisplayName() throws {
        var confirmedIDs: [String] = []
        var confirmedNames: [String] = []
        let verbs = CloudMachineMenuVerbs(
            openShell: { _ in }, newWorkspace: { _ in }, openDesktop: { _ in },
            runCommand: { _, _ in }, promptRename: { _ in }, copyToPasteboard: { _ in },
            confirmDelete: {
                confirmedIDs.append($0.id)
                confirmedNames.append($0.displayName)
            }, promptUpgrade: {}
        )
        let initial = MachineSnapshot(id: "vm-opaque-16336", provider: "freestyle", image: "cmux-devbox", isDesktop: false, activity: .ready, slug: "crisp-rose-piglet")
        let renamed = MachineSnapshot(id: initial.id, provider: initial.provider, image: initial.image, isDesktop: false, activity: .ready, label: "new-cloud-name", slug: initial.slug)
        for machine in [initial, renamed] {
            let entry = try #require(verbs.deleteEntries(machine).first)
            guard case .action(let action) = entry else { Issue.record("Delete entry should be an action"); return }
            action.perform()
        }
        #expect(confirmedIDs == [initial.id, renamed.id])
        #expect(confirmedNames == [initial.displayName, renamed.displayName])
    }

    @Test("Delete title uses a named machine and falls back for a blank name")
    func deleteConfirmationTitleUsesReadableName() {
        let format = String(localized: "machines.delete.title", defaultValue: "Delete machine “%@”?")
        let named = MachineSnapshot(
            id: "vm-opaque-16336",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            slug: "crisp-rose-piglet"
        )
        #expect(MachineRowActions.deleteConfirmationTitle(for: named) == String(format: format, "crisp-rose-piglet"))

        let blank = MachineSnapshot(
            id: named.id,
            provider: named.provider,
            image: named.image,
            isDesktop: named.isDesktop,
            activity: named.activity,
            label: " ",
            slug: "\t"
        )
        #expect(MachineRowActions.deleteConfirmationTitle(for: blank) == String(format: format, "vm-opaque-16336"))
    }

    @Test("The shared AppKit renderer renders a fixture with a status dot and dimmed detail")
    func appKitRendering() throws {
        let recorder = Recorder()
        let machine = Self.machine("m0")
        let entries: [CloudMenuEntry] = [.submenu(CloudMenuSubmenu(
            id: "machine.\(machine.id)", title: machine.displayName,
            detail: "Fixture ready", tone: CloudMenuTone(machine),
            children: recorder.machine.submenuEntries(machine)
        ))]
        let items = CloudMenuAppKitRenderer.items(entries)
        let row = try #require(items.first { $0.identifier?.rawValue == "machine.m0" })
        #expect(row.image != nil)
        #expect(row.attributedTitle?.string.hasPrefix("m0") == true)
        let open = try #require(row.submenu?.items.first { $0.identifier?.rawValue == "machine.m0.openShell" })
        let target = try #require(open.target as? NSObject)
        _ = target.perform(open.action, with: open)
        #expect(recorder.log == ["shell:m0"])
    }

    @Test("Explicit presentation reuses a fresh fleet, and a team switch drops it")
    func explicitPresentationRefreshPolicy() async throws {
        let center = NotificationCenter()
        let reads = ReadCounter()
        let model = CloudMenuModel(
            center: center,
            listMachines: {
                reads.count += 1
                return VMListPage(vms: [VMSummary(id: "vm-\(reads.count)", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)])
            },
            isAvailable: { true },
            pinStore: { nil },
            isFeatureEnabled: { true }
        )
        _ = await model.fleetPageForPresentation()
        #expect(model.machines.map(\.id) == ["vm-1"])
        _ = await model.fleetPageForPresentation()
        #expect(reads.count == 1)

        center.post(name: .cmuxCloudTeamScopeDidChange, object: nil)
        #expect(model.machines.isEmpty)
        #expect(model.loadState == .idle)
        _ = await model.fleetPageForPresentation()
        #expect(model.machines.map(\.id) == ["vm-2"])
    }

    @Test("A read that lands after a scope change recovers the explicit presentation")
    func scopeChangeDuringReadRecovers() async throws {
        let reads = ReadCounter()
        let scope = ScopeBox(value: "team:personal")
        let model = CloudMenuModel(
            center: NotificationCenter(),
            listMachines: {
                reads.count += 1
                // The team is confirmed while the first read is in flight.
                if reads.count == 1 { scope.value = "team:confirmed" }
                return VMListPage(vms: [VMSummary(id: "vm-\(reads.count)", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)])
            },
            isAvailable: { true },
            pinStore: { nil },
            scope: { scope.value },
            isFeatureEnabled: { true }
        )
        _ = await model.fleetPageForPresentation()
        #expect(model.machines.map(\.id) == ["vm-2"])
    }

    @Test("Initialization, feature changes and scope invalidation do not read the fleet")
    func idleModelDoesNotReadFleet() async {
        let center = NotificationCenter()
        let reads = ReadCounter()
        let scope = ScopeBox(value: "account-a:team-a")
        var enabled = true
        let model = CloudMenuModel(
            center: center,
            listMachines: {
                reads.count += 1
                return VMListPage(vms: [VMSummary(
                    id: scope.value ?? "none", provider: "freestyle", status: "running",
                    image: "cmux-devbox", createdAt: 0
                )])
            },
            isAvailable: { enabled && scope.value != nil },
            pinStore: { nil },
            scope: { scope.value },
            isFeatureEnabled: { enabled }
        )
        #expect(reads.count == 0)
        enabled = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        scope.value = "account-b:team-a"
        center.post(name: .cmuxCloudVMAccessDidEnd, object: nil)
        scope.value = "account-b:team-b"
        center.post(name: .cmuxCloudTeamScopeDidChange, object: nil)
        #expect(reads.count == 0)
        #expect(model.fleetPage == nil && model.loadState == .idle)
        let page = await model.fleetPageForPresentation()
        #expect(page?.vms.map(\.id) == ["account-b:team-b"])
        #expect(reads.count == 1)
        scope.value = nil
        center.post(name: .cmuxCloudVMAccessDidEnd, object: nil)
        #expect(model.fleetPage == nil && model.machines.isEmpty)
        #expect(await model.fleetPageForPresentation() == nil)
        #expect(reads.count == 1)
    }

    @Test("Shared entry signatures preserve identical fixtures and detect visible rename or status changes")
    func signatureTracksVisibleChanges() {
        let recorder = Recorder()
        func entries(_ machine: MachineSnapshot, detail: String = "Fixture ready") -> [CloudMenuEntry] {
            [.submenu(CloudMenuSubmenu(
                id: "machine.\(machine.id)", title: machine.displayName,
                detail: detail, tone: CloudMenuTone(machine),
                children: recorder.machine.submenuEntries(machine)
            ))]
        }
        let same = CloudMenuEntry.signature(entries(Self.machine("m0")))
        #expect(same == CloudMenuEntry.signature(entries(Self.machine("m0"))))
        let renamed = MachineSnapshot(id: "m0", provider: "freestyle", image: "cmux-devbox", isDesktop: false, activity: .ready, label: "renamed")
        #expect(same != CloudMenuEntry.signature(entries(renamed)))
        let pending = MachineSnapshot(id: "m0", provider: "freestyle", image: "cmux-devbox", isDesktop: false, activity: .pending)
        #expect(same != CloudMenuEntry.signature(entries(pending, detail: "Fixture pending")))
    }

    // MARK: Fixtures

    @MainActor
    final class ReadCounter { var count = 0 }

    @MainActor
    final class ScopeBox {
        var value: String?
        init(value: String?) { self.value = value }
    }

    @MainActor
    final class Recorder {
        var log: [String] = []

        var machine: CloudMachineMenuVerbs {
            CloudMachineMenuVerbs(
                openShell: { self.log.append("shell:\($0)") },
                newWorkspace: { self.log.append("newWorkspace:\($0)") },
                openDesktop: { self.log.append("desktop:\($0)") },
                runCommand: { self.log.append("run:\($0):\($1.joined(separator: " "))") },
                promptRename: { machine in self.log.append("rename:\(machine.id)") },
                copyToPasteboard: { self.log.append("copy:\($0)") },
                confirmDelete: { self.log.append("delete:\($0.id)") },
                promptUpgrade: { self.log.append("upgradeMachine") },
                fork: { self.log.append("fork:\($0.id)") }
            )
        }
    }

    static func machine(_ id: String, isDesktop: Bool = false) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "freestyle", image: "cmux-devbox", isDesktop: isDesktop, activity: .ready)
    }

    static func actionID(_ entry: CloudMenuEntry) -> String? {
        if case .action(let action) = entry { return action.id }
        return nil
    }

    static func action(_ id: String, in entries: [CloudMenuEntry]) -> CloudMenuAction? {
        for entry in entries {
            switch entry {
            case .action(let action) where action.id == id: return action
            case .submenu(let submenu): if let found = action(id, in: submenu.children) { return found }
            default: continue
            }
        }
        return nil
    }

    static func perform(_ id: String, in entries: [CloudMenuEntry]) throws {
        try #require(action(id, in: entries)).perform()
    }

    /// Polls until the predicate holds; the deadline only bounds a real failure.
    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }
}
