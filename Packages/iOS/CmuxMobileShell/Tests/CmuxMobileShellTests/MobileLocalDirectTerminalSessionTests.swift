import CMUXMobileCore
import Foundation
import Observation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectTerminalSessionTests {
    private func session(_ rpc: DirectTerminalRPCFixture) -> MobileLocalDirectTerminalSession {
        var generation: UInt64 = 0
        return .init(rpc: rpc, workspaceID: DirectTerminalRPCFixture.workspace, surfaceID: DirectTerminalRPCFixture.surface,
            clientID: "fixture-device", connectionGeneration: 1,
            capabilities: ["terminal.render_grid.v1", "terminal.render_grid.screen_anchor.v1", MobileTerminalInputDelivery.capability],
            nextViewportGeneration: { generation += 1; return generation })
    }
    private func mount(_ session: MobileLocalDirectTerminalSession, _ sink: DirectTerminalRenderSink) {
        session.resize(columns: 20, rows: 5, reportID: 1)
        session.mount(apply: sink.apply, confirmViewport: { _, _, _ in })
    }
    private func wait(_ session: MobileLocalDirectTerminalSession, _ state: MobileLocalDirectTerminalSession.State) async {
        while session.state != state {
            if session.state == .failed || session.state == .incompatible { Issue.record("Unexpected terminal failure"); return }
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = session.state } onChange: { continuation.resume() }
            }
        }
    }
    @Test func snapshotDeltaStaleGapAndHydration() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        let terminal = session(rpc); mount(terminal, sink)
        await wait(terminal, .ready)
        #expect(terminal.ownsLocalPrimaryScroll)
        try await rpc.emit(DirectTerminalRPCFixture.frame(revision: 2, base: 1))
        var applied = sink.applied.stream.makeAsyncIterator()
        #expect(await applied.next() == 1); #expect(await applied.next() == 2)
        try await rpc.emit(DirectTerminalRPCFixture.frame(revision: 2, base: 1))
        try await rpc.emit(DirectTerminalRPCFixture.frame(revision: 4, base: 3))
        #expect(await applied.next() == 5)
        #expect(sink.frames.map(\.renderRevision) == [1, 2, 5])
        #expect(await rpc.replays == 2)
        #expect(String(decoding: sink.bytes, as: UTF8.self).contains("中"))
        let requests = await rpc.requests
        let replayParams = try requests.compactMap { data -> [String: Any]? in
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return value?["method"] as? String == "mobile.terminal.replay" ? value?["params"] as? [String: Any] : nil
        }
        #expect(replayParams.first?["max_scrollback_rows"] as? Int == MobileTerminalScrollbackPreference.resolve())
        #expect(replayParams.last?["max_scrollback_rows"] as? Int == 0)
        terminal.invalidate(); await rpc.disconnect()
    }
    @Test func eventsDuringReplayApplyAfterBaselineAndInputPreservesBytes() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        await rpc.configure(holdReplay: true)
        let terminal = session(rpc); mount(terminal, sink)
        var calls = rpc.calls.stream.makeAsyncIterator()
        while await calls.next() != "mobile.terminal.replay" {}
        try await rpc.emit(DirectTerminalRPCFixture.frame(revision: 2, base: 1))
        await rpc.releaseReplay()
        var applied = sink.applied.stream.makeAsyncIterator()
        #expect(await applied.next() == 1); #expect(await applied.next() == 2)
        await wait(terminal, .ready)
        terminal.input(Data([0xE4])); terminal.input(Data([0xB8, 0xAD])); terminal.input(Data([3, 13]))
        while await calls.next() != "mobile.terminal.input" {}
        #expect(await rpc.inputs.joined() == "中\u{3}\r")
        #expect(await rpc.deliveries.map(\.sequence) == [1])
        terminal.invalidate()
        terminal.input(Data("late".utf8))
        #expect(terminal.state == .disconnected)
        await rpc.disconnect()
    }
    @Test func detachRequiresExplicitReattach() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        let terminal = session(rpc); mount(terminal, sink)
        await wait(terminal, .ready)
        try await rpc.detach(); await wait(terminal, .detached)
        terminal.input(Data("blocked".utf8)); terminal.requestReplay()
        #expect(await rpc.replays == 1); #expect(await rpc.inputs.isEmpty)
        terminal.reattach(); await wait(terminal, .ready)
        #expect(await rpc.replays == 2)
        terminal.invalidate(); await rpc.disconnect()
    }
    @Test func retirementDropsQueuedInputWithoutResending() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        await rpc.configure(holdInput: true)
        let terminal = session(rpc); mount(terminal, sink); await wait(terminal, .ready)
        terminal.input(Data("first".utf8))
        var calls = rpc.calls.stream.makeAsyncIterator()
        while await calls.next() != "mobile.terminal.input" {}
        terminal.input(Data("unsent".utf8)); terminal.invalidate()
        await rpc.releaseInput()
        #expect(await rpc.inputs == ["first"])
        #expect(terminal.state == .disconnected)
        await rpc.disconnect()
    }
    @Test func resizeAcknowledgementRejectsOldReportAndDoesNotPingPong() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        await rpc.configure(holdViewport: true)
        let terminal = session(rpc)
        var confirmations: [UInt64] = []
        terminal.resize(columns: 20, rows: 5, reportID: 1)
        terminal.mount(apply: sink.apply, confirmViewport: { _, _, id in confirmations.append(id) })
        var calls = rpc.calls.stream.makeAsyncIterator()
        while await calls.next() != "mobile.terminal.viewport" {}
        terminal.resize(columns: 30, rows: 5, reportID: 2)
        await rpc.releaseViewport(); await wait(terminal, .ready)
        #expect(confirmations == [2])
        terminal.resize(columns: 30, rows: 5, reportID: 3)
        #expect(confirmations == [2, 3])
        let requests = await rpc.requests
        let count = try requests.filter { data in
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["method"] as? String == "mobile.terminal.viewport"
        }.count
        #expect(count == 2)
        terminal.invalidate(); await rpc.disconnect()
    }
    @Test func reentrantLayoutDuringViewportConfirmationReachesReady() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        let terminal = session(rpc)
        let completion = AsyncStream<Bool>.makeStream()
        var confirmations: [UInt64] = []
        terminal.resize(columns: 20, rows: 5, reportID: 1)
        terminal.mount(apply: { frame, bytes in
            let applied = await sink.apply(frame, bytes)
            completion.continuation.yield(applied)
            return applied
        }, confirmViewport: { _, _, id in
            confirmations.append(id)
            if id == 1 {
                // A new natural layout arrives while the old viewport owner is confirming.
                terminal.resize(columns: 30, rows: 5, reportID: 2)
                terminal.input(Data("must-not-send".utf8))
            }
        })
        // A liveness deadline, not a delay used to order callbacks or settle state.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { completion.continuation.yield(false) }
        }
        var results = completion.stream.makeAsyncIterator()
        let applied = await results.next()
        deadline.cancel()
        #expect(applied == true, "Newest viewport must reach screen replay and renderer acknowledgement")
        #expect(confirmations == [1, 2])
        if applied == true { await wait(terminal, .ready) }
        #expect(terminal.state == .ready)
        #expect(await rpc.replays == 1)
        #expect(await rpc.inputs.isEmpty)
        terminal.invalidate(); await rpc.disconnect()
    }

    @Test func lateLayoutAfterConfirmationReachesReady() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        let terminal = session(rpc); mount(terminal, sink)
        await wait(terminal, .ready)
        terminal.resize(columns: 30, rows: 6, reportID: 2)
        await wait(terminal, .ready)
        #expect(await rpc.replays == 2)
        #expect(sink.frames.count == 2)
        terminal.invalidate(); await rpc.disconnect()
    }

    @Test func alternatingNaturalRowsWithSmallerEffectiveGridRemainReady() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        let terminal = session(rpc)
        var confirmations: [UInt64] = []
        terminal.resize(columns: 63, rows: 69, reportID: 1)
        terminal.mount(apply: sink.apply, confirmViewport: { columns, rows, id in
            // The fixture grants 20x5, deliberately smaller than natural capacity.
            #expect(columns == 20 && rows == 5)
            confirmations.append(id)
        })
        await wait(terminal, .ready)
        terminal.resize(columns: 63, rows: 68, reportID: 2)
        await wait(terminal, .ready)
        terminal.resize(columns: 63, rows: 69, reportID: 3)
        await wait(terminal, .ready)
        #expect(confirmations == [1, 2, 3])
        #expect(await rpc.replays == 3)
        #expect(sink.frames.count == 3)
        #expect(await rpc.inputs.isEmpty)
        terminal.invalidate(); await rpc.disconnect()
    }

    @Test(arguments: [false, true])
    func retirementDuringConfirmationDoesNotReplay(invalidate: Bool) async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        let terminal = session(rpc)
        let confirmed = AsyncStream<Bool>.makeStream()
        terminal.resize(columns: 20, rows: 5, reportID: 1)
        terminal.mount(apply: sink.apply, confirmViewport: { _, _, _ in
            terminal.resize(columns: 30, rows: 6, reportID: 2)
            if invalidate { terminal.invalidate() } else { terminal.unmount() }
            confirmed.continuation.yield(true)
        })
        var confirmations = confirmed.stream.makeAsyncIterator()
        #expect(await confirmations.next() == true)
        #expect(terminal.state == .disconnected)
        #expect(await rpc.replays == 0)
        let requests = await rpc.requests
        let reports = try requests.filter {
            let value = try JSONSerialization.jsonObject(with: $0) as? [String: Any]
            let params = value?["params"] as? [String: Any]
            return value?["method"] as? String == "mobile.terminal.viewport" && params?["clear"] as? Bool != true
        }
        #expect(reports.count == 1)
        #expect(sink.frames.isEmpty)
        terminal.invalidate(); await rpc.disconnect()
    }

    @Test func detachDuringViewportReplyDoesNotRevive() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        await rpc.configure(holdViewport: true)
        let terminal = session(rpc); mount(terminal, sink)
        var calls = rpc.calls.stream.makeAsyncIterator()
        while await calls.next() != "mobile.terminal.viewport" {}
        try await rpc.detach(); await wait(terminal, .detached)
        await rpc.releaseViewport()
        terminal.resize(columns: 30, rows: 6, reportID: 2)
        terminal.requestReplay(); terminal.input(Data("blocked".utf8))
        #expect(terminal.state == .detached)
        #expect(await rpc.replays == 0)
        #expect(await rpc.inputs.isEmpty)
        terminal.invalidate(); await rpc.disconnect()
    }

    @Test func replayRaceOverflowCoalescesOneRepair() async throws {
        let rpc = DirectTerminalRPCFixture(), sink = DirectTerminalRenderSink()
        await rpc.configure(holdReplay: true)
        let terminal = session(rpc); mount(terminal, sink)
        var calls = rpc.calls.stream.makeAsyncIterator()
        while await calls.next() != "mobile.terminal.replay" {}
        for revision in UInt64(2)...41 { try await rpc.emit(DirectTerminalRPCFixture.frame(revision: revision, base: revision - 1)) }
        await rpc.releaseReplay()
        await wait(terminal, .ready)
        #expect(await rpc.replays == 2)
        #expect(sink.frames.last?.renderRevision == 42)
        terminal.invalidate(); await rpc.disconnect()
    }

}
