import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

@Suite struct LocalTerminalSizingHostTests {
    private let me = TerminalSharingIdentity(userID: "u_me", displayName: "Me", deviceName: "Mac")

    private func host(
        mac: TerminalGridSize = TerminalGridSize(cols: 200, rows: 60),
        policy: TerminalSizingPolicy = .latest
    ) -> LocalTerminalSizingHost {
        LocalTerminalSizingHost(
            macParticipant: me.participant(id: "mac:pane", deviceKind: .mac, viewport: mac),
            initialSize: mac,
            policy: policy
        )
    }

    private func phone(_ client: String, user: String? = "u_me", cols: Int = 50, rows: Int = 30) -> TerminalSizingParticipant {
        TerminalSizingParticipant(
            id: LocalTerminalSizingHost.phoneParticipantID(clientID: client),
            userID: user, deviceKind: .iphone, deviceName: "iPhone",
            viewport: TerminalGridSize(cols: cols, rows: rows)
        )
    }

    @Test func directIPadControlsGridUntilExplicitDisconnect() {
        var sizing = host(mac: TerminalGridSize(cols: 120, rows: 31), policy: .fitEveryone)
        sizing.syncPhones([phone("ipad", cols: 63, rows: 69)], controllingClientID: "ipad")
        #expect(sizing.state.size == TerminalGridSize(cols: 63, rows: 69))
        sizing.noteActivity("mac:pane")
        sizing.updateMacViewport(TerminalGridSize(cols: 140, rows: 35))
        #expect(sizing.state.size == TerminalGridSize(cols: 63, rows: 69))
        // A transport loss is not a user disconnect. Keep the last iPad grid.
        sizing.syncPhones([])
        #expect(sizing.state.size == TerminalGridSize(cols: 63, rows: 69))
        sizing.syncPhones([phone("ipad", cols: 91, rows: 43)], controllingClientID: "ipad")
        #expect(sizing.state.size == TerminalGridSize(cols: 91, rows: 43))
        sizing.disconnect("mobile:ipad", detachment: TerminalSharingDetachment(
            reason: .disconnectedBy(me.detachActor), at: Date(timeIntervalSince1970: 0)))
        #expect(sizing.state.policy == .fitEveryone)
        #expect(sizing.applyTarget == .uncapped)
        #expect(sizing.state.size == TerminalGridSize(cols: 140, rows: 35))
    }

    @Test func directReleaseRestoresPreviousPolicyWithoutRevokingOrDetachingDevice() {
        var sizing = host(policy: .latest)
        sizing.syncPhones([phone("ipad", cols: 63, rows: 69)], controllingClientID: "ipad")
        let unrelatedReleased = sizing.releasePhoneControl(clientID: "unrelated")
        #expect(!unrelatedReleased)
        #expect(sizing.controllingPhoneID == "mobile:ipad")
        let released = sizing.releasePhoneControl(clientID: "ipad")
        #expect(released)
        sizing.syncPhones([])
        #expect(sizing.state.policy == .latest)
        #expect(sizing.applyTarget == .uncapped)
        #expect(!sizing.isDetached("mobile:ipad"))
        sizing.syncPhones([phone("ipad", cols: 80, rows: 45)], controllingClientID: "ipad")
        #expect(sizing.state.size == TerminalGridSize(cols: 80, rows: 45))
    }

    @Test func directDeviceIdentityPreventsOtherPhoneActivityTakingControl() {
        var sizing = host()
        var ipad = phone("ipad", cols: 63, rows: 69)
        ipad.deviceID = "ipad-install"
        var other = phone("other", cols: 50, rows: 25)
        other.deviceID = "other-install"
        sizing.syncPhones([ipad, other], controllingClientID: "ipad")
        sizing.setCountsOverride(other.id, true)
        sizing.noteActivity(other.id)
        sizing.noteActivity("mac:pane")
        #expect(sizing.state.size == TerminalGridSize(cols: 63, rows: 69))
    }

    @Test func matchingMacDimensionsDoNotGiveUpDirectControl() {
        let grid = TerminalGridSize(cols: 63, rows: 69)
        var sizing = host(mac: grid)
        sizing.syncPhones([phone("ipad", cols: 63, rows: 69)], controllingClientID: "ipad")
        #expect(sizing.applyTarget == .grid(grid))
        sizing.updateMacViewport(TerminalGridSize(cols: 140, rows: 35))
        #expect(sizing.applyTarget == .grid(grid))
    }

    @Test func defaultFitsEveryoneIncludingMyPhone() {
        var h = host(policy: .fitEveryone)
        h.syncPhones([phone("a")])
        #expect(h.state.participant("mobile:a")?.counts == true)
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 50, rows: 30)))
    }

    /// The replay registers the phone before capture, so one connect is one
    /// grid change: straight to the fitted grid, with no step through the
    /// Mac-only size, and the phone's follow-up report of the same viewport
    /// changes nothing.
    @Test func oneConnectIsExactlyOneGridChange() {
        var h = host(mac: TerminalGridSize(cols: 120, rows: 40), policy: .fitEveryone)
        let before = h.state
        var targets: [TerminalSizingApplyTarget] = []
        if h.syncPhones([phone("a", cols: 54, rows: 26)]) { targets.append(h.applyTarget) }
        if h.syncPhones([phone("a", cols: 54, rows: 26)]) { targets.append(h.applyTarget) }
        #expect(targets == [.grid(TerminalGridSize(cols: 54, rows: 26))])
        #expect(h.state.generation == before.generation + 1)
        #expect(h.state.size == TerminalGridSize(cols: 54, rows: 26))
    }

    @Test func macAloneIsUncapped() {
        #expect(host().applyTarget == .uncapped)
    }

    @Test func sameUserPhoneDefersToMacSoTheMacStaysUncapped() {
        var h = host()
        h.syncPhones([phone("a")])
        #expect(h.state.participant("mobile:a")?.counts == false)
        #expect(h.applyTarget == .uncapped)
    }

    @Test func otherUserPhoneTakesTheGridByLatestActivity() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 50, rows: 30)))
        h.noteActivity("mac:pane")
        #expect(h.applyTarget == .uncapped)
    }

    @Test func smallestPolicyReplacesTheLegacyMinimum() {
        var h = host()
        h.setPolicy(TerminalSizingPolicy(mode: .smallest))
        h.syncPhones([phone("a", cols: 80, rows: 70), phone("b", user: "u_b", cols: 90, rows: 20)])
        h.setCountsOverride("mobile:a", true)
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 80, rows: 20)))
    }

    @Test func disconnectBlocksReportsUntilReattachAsViewer() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        let detachment = TerminalSharingDetachment(reason: .disconnectedBy(me.detachActor), at: Date(timeIntervalSince1970: 0))
        let disconnected = h.disconnect("mobile:a", detachment: detachment)
        #expect(disconnected)
        #expect(h.isDetached("mobile:a"))
        h.syncPhones([phone("a", user: "u_other")])
        #expect(h.state.participant("mobile:a") == nil)
        #expect(h.applyTarget == .uncapped)
        h.reattach("mobile:a", asViewer: true)
        h.syncPhones([phone("a", user: "u_other")])
        #expect(h.state.participant("mobile:a")?.participant.countsOverride == false)
        #expect(h.applyTarget == .uncapped)
    }

    /// tmux `detach-client` on the host's own view: the terminal keeps
    /// running and every other viewer keeps its session; the Mac pane stops
    /// counting and ignores its own resizes and input until it reattaches.
    @Test func macViewDetachesWhileTheTerminalAndPhonesStay() {
        var h = host()
        h.syncPhones([phone("a")])
        #expect(h.state.participant("mobile:a")?.counts == false)
        let detachment = TerminalSharingDetachment(reason: .disconnectedBy(me.detachActor), at: Date(timeIntervalSince1970: 0))
        let disconnected = h.disconnect("mac:pane", detachment: detachment)
        #expect(disconnected)
        #expect(h.isDetached("mac:pane"))
        #expect(h.macDetachment == detachment)
        #expect(h.state.participant("mac:pane") == nil)
        #expect(h.state.participant("mobile:a")?.counts == true)
        #expect(h.state.owners == ["mobile:a"])
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 50, rows: 30)))
        let resized = h.updateMacViewport(TerminalGridSize(cols: 180, rows: 50))
        let typed = h.noteActivity("mac:pane")
        #expect(!resized)
        #expect(!typed)
        #expect(h.state.participant("mac:pane") == nil)
        h.syncPhones([phone("a")])
        #expect(h.state.participant("mac:pane") == nil)
    }

    @Test func macReattachRestoresItsViewWithTheLatestPaneGrid() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        _ = h.disconnect("mac:pane", detachment: TerminalSharingDetachment(reason: .disconnectedBy(nil), at: Date()))
        h.updateMacViewport(TerminalGridSize(cols: 180, rows: 50))
        let reattached = h.reattach("mac:pane", asViewer: true)
        #expect(reattached)
        #expect(!h.isDetached("mac:pane"))
        let row = h.state.participant("mac:pane")
        #expect(row?.participant.viewport == TerminalGridSize(cols: 180, rows: 50))
        #expect(row?.participant.countsOverride == false)
        #expect(h.state.owners == ["mobile:a"])
        let again = h.reattach("mac:pane", asViewer: false)
        #expect(!again)
    }

    @Test func macReattachAsParticipantTakesTheGridBack() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        _ = h.disconnect("mac:pane", detachment: TerminalSharingDetachment(reason: .disconnectedBy(nil), at: Date()))
        let reattached = h.reattach("mac:pane", asViewer: false)
        #expect(reattached)
        #expect(h.state.owners == ["mac:pane"])
        #expect(h.applyTarget == .uncapped)
    }

    @Test func droppedPhoneLeavesAndGridFollowsTheMacPane() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        h.syncPhones([])
        #expect(h.phoneParticipantIDs.isEmpty)
        h.updateMacViewport(TerminalGridSize(cols: 150, rows: 40))
        #expect(h.state.size == TerminalGridSize(cols: 150, rows: 40))
        #expect(h.applyTarget == .uncapped)
    }
}
