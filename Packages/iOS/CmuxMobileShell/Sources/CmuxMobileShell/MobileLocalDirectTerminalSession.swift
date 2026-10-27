public import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import CmuxMobileShellModel
import Observation

/// One selected existing terminal on the controller's shared admitted RPC connection.
/// Never dials, creates a terminal, or retries uncertain input.
@MainActor @Observable
public final class MobileLocalDirectTerminalSession {
    /// Safe terminal presentation and input gate.
    public enum State: Equatable, Sendable { case disconnected, loading, ready, detached, incompatible, failed }
    /// Explicit Mac workspace target.
    public let workspaceID: String
    /// Explicit existing terminal target.
    public let surfaceID: String
    /// Parent connection generation; a new connection creates a new session.
    public let connectionGeneration: UInt64
    /// Current readiness; only ready permits input.
    public private(set) var state: State = .disconnected
    /// Confirmed primary-screen ownership, never inferred from the local emulator.
    public private(set) var ownsLocalPrimaryScroll = false
    @ObservationIgnored private let rpc: any MobileSyncing
    @ObservationIgnored private let clientID: String
    @ObservationIgnored private let capable: Bool
    @ObservationIgnored private let nextGeneration: @MainActor () -> UInt64
    @ObservationIgnored private var apply: (@MainActor (MobileTerminalRenderGridFrame, Data) async -> Bool)?
    @ObservationIgnored private var confirm: (@MainActor (Int, Int, UInt64) -> Void)?
    @ObservationIgnored private var valid = true
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var streamID = UUID().uuidString
    @ObservationIgnored private var inputStream = UUID()
    @ObservationIgnored private var inputSequence: UInt64 = 0
    @ObservationIgnored private var inputGeneration: UInt64 = 0
    @ObservationIgnored private var sizeStateGeneration: UInt64 = 0
    @ObservationIgnored private var viewportFloor: (String, UInt64)?
    @ObservationIgnored private var outputGeneration: UInt64 = 0
    @ObservationIgnored private var gestureGeneration: UInt64 = 0
    @ObservationIgnored private var inputBuffer = MobileTerminalInputSendBuffer()
    @ObservationIgnored private var utf8Tail = Data()
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var viewportTask: Task<Void, Never>?
    @ObservationIgnored private var gestureTask: Task<Void, Never>?
    @ObservationIgnored private var gestures: [(String, [String: Any])] = []
    @ObservationIgnored private var subscribed = false
    @ObservationIgnored private var pendingFrames: [Data] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var needsReplay = true
    @ObservationIgnored private var reattachRequested = false
    @ObservationIgnored private var hydrated = false
    @ObservationIgnored private var delivered: MobileTerminalRenderGridFrame?
    @ObservationIgnored private var repairFailures = 0
    @ObservationIgnored private var viewport: (MobileTerminalViewportSize, UInt64, UInt64)?
    @ObservationIgnored private var effectiveGrid: MobileTerminalViewportSize?
    @ObservationIgnored private var viewportPending = false

    #if DEBUG
    @ObservationIgnored private var traceCount = 0
    private func trace(_ stage: String) {
        guard traceCount < 64, state != .ready else { return }
        traceCount += 1
        NSLog("[direct-terminal] %@", stage)
    }
    #endif

    /// Constructs an idle session with no network side effects and no capability token.
    public init(rpc: any MobileSyncing, workspaceID: String, surfaceID: String, clientID: String,
                connectionGeneration: UInt64, capabilities: Set<String>, nextViewportGeneration: @escaping @MainActor () -> UInt64) {
        self.rpc = rpc; self.workspaceID = workspaceID; self.surfaceID = surfaceID; self.clientID = clientID
        self.connectionGeneration = connectionGeneration; nextGeneration = nextViewportGeneration
        capable = capabilities.isSuperset(of: ["terminal.render_grid.v1", "terminal.render_grid.screen_anchor.v1", MobileTerminalInputDelivery.capability])
    }

    /// Mounts a fresh renderer. The sink must return true only after ordered Ghostty application succeeds.
    public func mount(apply: @escaping @MainActor (MobileTerminalRenderGridFrame, Data) async -> Bool,
                      confirmViewport: @escaping @MainActor (Int, Int, UInt64) -> Void) {
        guard valid, !mounted else { return }
        #if DEBUG
        traceCount = 0
        trace("mount.enter")
        #endif
        guard capable else { state = .incompatible; return }
        mounted = true; epoch &+= 1; sizeStateGeneration = 0; viewportFloor = nil
        self.apply = apply; confirm = confirmViewport; hydrated = false; delivered = nil
        needsReplay = true; repairFailures = 0; streamID = UUID().uuidString; inputStream = UUID(); inputSequence = 0
        let token = epoch
        if state != .detached { state = .loading }
        setupTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.rpc.subscribe(to: ["terminal.render_grid", "mobile.terminal.size_state", "mobile.terminal.detached"])
            guard self.current(token) else { return }
            self.eventTask = Task { [weak self] in
                for await event in events {
                    guard let self, self.current(token) else { return }
                    self.receive(event)
                }
            }
            do {
                _ = try await self.request("mobile.events.subscribe", ["stream_id": self.streamID, "client_id": self.clientID,
                    "topics": ["terminal.render_grid", "mobile.terminal.size_state", "mobile.terminal.detached"],
                    "event_transport": "control_v1", "render_grid_anchor": "screen"])
                guard self.current(token) else { return }
                #if DEBUG
                self.trace("subscribe.complete")
                #endif
                self.subscribed = true; self.sendViewport()
            } catch { self.fail(error, token: token) }
        }
    }

    /// Stops renderer work and unsubscribes this stream. Sizing control belongs to the
    /// admitted device and survives renderer teardown, backgrounding and reconnection.
    public func unmount() {
        let wasMounted = mounted
        let oldStream = streamID
        mounted = false; epoch &+= 1; subscribed = false
        for task in [setupTask, eventTask, outputTask, inputTask, viewportTask, gestureTask] { task?.cancel() }
        setupTask = nil; eventTask = nil; outputTask = nil; inputTask = nil; viewportTask = nil; gestureTask = nil
        inputBuffer.clear(); utf8Tail.removeAll(); gestures.removeAll(); pendingFrames.removeAll(); pendingBytes = 0
        delivered = nil; effectiveGrid = nil; ownsLocalPrimaryScroll = false; apply = nil; confirm = nil
        if state != .detached && state != .incompatible { state = .disconnected }
        guard wasMounted else { return }
        let rpc = rpc
        Task {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "method": "mobile.events.unsubscribe", "params": ["stream_id": oldStream]
            ]) {
                _ = try? await rpc.sendRequest(data, timeoutNanoseconds: 1_000_000_000)
            }
        }
    }

    /// Permanently retires this selection/connection owner; late callbacks cannot mount or send again.
    public func invalidate() { valid = false; unmount() }

    /// Records the newest natural layout. Generation allocation outlives individual renderer instances.
    public func resize(columns: Int, rows: Int, reportID: UInt64) {
        guard valid, columns > 0, rows > 0 else { return }
        let size = MobileTerminalViewportSize(columns: min(columns, 300), rows: min(rows, 120))
        if viewport?.0 == size {
            viewport?.1 = reportID
            if let grid = effectiveGrid, !viewportPending { confirm?(grid.columns, grid.rows, reportID) }
            return
        }
        viewport = (size, reportID, nextGeneration()); viewportPending = true
        #if DEBUG
        trace("resize cols=\(size.columns) rows=\(size.rows) generation=\(viewport!.2)")
        #endif
        if state == .ready { state = .loading }
        sendViewport()
    }

    /// Requests a bounded authoritative repair, coalescing all concurrent triggers.
    public func requestReplay() {
        guard valid, mounted, state != .detached, state != .incompatible, state != .failed else { return }
        needsReplay = true; state = .loading; scheduleOutput()
    }

    /// A rebuilt/blank Ghostty surface must hydrate history again, unlike ordinary repairs.
    public func rendererRebuilt() { hydrated = false; delivered = nil; requestReplay() }
    /// Fails closed when the local renderer cannot be created or recovered.
    public func rendererUnavailable() { stopInput() }

    /// Only this explicit user action lifts a server detachment.
    public func reattach() {
        guard state == .detached, mounted else { return }
        resetInputStream()
        reattachRequested = true; state = .loading; needsReplay = true
        viewportPending = false; effectiveGrid = viewport?.0
        scheduleOutput()
    }

    /// Synchronously enqueues UTF-8/control bytes, preserving callback order and incomplete scalar boundaries.
    public func input(_ bytes: Data) { _ = enqueueInput(bytes) }

    /// Admits literal UTF-8 without Return or framing, preserving pending typed input on rejection.
    /// True means locally queued, not acknowledged by the host or safe in every active program.
    public func enqueueLiteralText(_ text: String) -> Bool {
        guard state == .ready, current(epoch), !viewportPending, utf8Tail.isEmpty, !text.isEmpty,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }),
              text.utf8.count <= MobileTerminalInputSendBuffer.maximumPendingByteCount - inputBuffer.pendingByteCount else { return false }
        return enqueueInput(Data(text.utf8))
    }

    private func enqueueInput(_ bytes: Data) -> Bool {
        guard state == .ready, current(epoch), !viewportPending else { return false }
        guard utf8Tail.count + bytes.count <= MobileTerminalInputSendBuffer.maximumPendingByteCount else { stopInput(); return false }
        utf8Tail.append(bytes)
        var complete = utf8Tail.count
        var text: String?
        for suffix in 0...min(3, utf8Tail.count) {
            complete = utf8Tail.count - suffix
            if let decoded = String(data: utf8Tail.prefix(complete), encoding: .utf8) { text = decoded; break }
        }
        guard let text, utf8Tail.count - complete <= 3 else { stopInput(); return false }
        utf8Tail.removeFirst(complete)
        let result = inputBuffer.enqueue(text, workspaceID: .init(rawValue: workspaceID), terminalID: .init(rawValue: surfaceID))
        if result == .rejected { stopInput(); return false }
        guard inputTask == nil else { return true }
        let token = epoch
        let generation = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token, self.inputGeneration == generation { self.inputTask = nil } }
            while self.current(token), self.inputGeneration == generation,
                  (self.state == .ready || self.state == .loading), let chunk = self.inputBuffer.nextBatch(maximumByteCount: 4096) {
                guard let surface = UUID(uuidString: self.surfaceID) else { self.stopInput(); return }
                self.inputSequence &+= 1
                let delivery = MobileTerminalInputDelivery(surfaceID: surface, streamID: self.inputStream, sequence: self.inputSequence)
                do {
                    var params = self.targetParameters
                    params["text"] = chunk.text
                    for (key, value) in delivery.rpcParameters { params[key] = value }
                    let data = try await self.request("mobile.terminal.input", params)
                    guard self.current(token), self.inputGeneration == generation else { return }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ack = MobileTerminalInputAcknowledgement.fromRPC(payload: object),
                          ack.streamID == delivery.streamID, ack.sequence == delivery.sequence,
                          ack.status == .applied || ack.status == .duplicate else { self.stopInput(); return }
                } catch {
                    guard self.current(token), self.inputGeneration == generation else { return }
                    self.fail(error, token: token); self.inputBuffer.clear(); return
                }
            }
            if self.epoch == token, self.inputGeneration == generation { self.inputBuffer.clear() }
        }
        return true
    }

    /// Alternate-screen wheel gestures use the host's existing mode-aware scroll handler.
    public func scroll(lines: Double, col: Int, row: Int) {
        guard !ownsLocalPrimaryScroll, lines.isFinite, lines != 0 else { return }
        enqueueGesture("mobile.terminal.scroll", ["delta_lines": max(-1000, min(1000, lines)), "col": col, "row": row])
    }
    /// Forwards a host-mode-aware click, never also synthesizing PTY mouse bytes.
    public func tap(col: Int, row: Int) { enqueueGesture("mobile.terminal.mouse", ["col": col, "row": row]) }

    private var targetParameters: [String: Any] { ["workspace_id": workspaceID, "surface_id": surfaceID, "client_id": clientID] }
    private var viewportParameters: MobileTerminalViewportParameters {
        .init(clientID: clientID, identity: .init(kind: .ipad, name: "iPad", model: "iPad", deviceID: clientID))
    }
    private var canApplyOutput: Bool { state == .loading || state == .ready }
    private func current(_ token: UInt64) -> Bool { valid && mounted && epoch == token && !Task.isCancelled }
    private func request(_ method: String, _ params: [String: Any]) async throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        do {
            return try await rpc.sendRequest(bytes, timeoutNanoseconds: 10_000_000_000)
        } catch {
            #if DEBUG
            trace("request.failed method=\(method) error=\(MobileLocalDirectFailureDiagnostic(error).kind)")
            #endif
            throw error
        }
    }
    private func resetInputStream() {
        inputGeneration &+= 1; inputTask?.cancel(); inputTask = nil
        inputBuffer.clear(); utf8Tail.removeAll(); inputStream = UUID(); inputSequence = 0
    }
    private func stopInput() { inputBuffer.clear(); utf8Tail.removeAll(); state = .failed; ownsLocalPrimaryScroll = false }
    private func fail(_ error: any Error, token: UInt64) {
        guard current(token) else { return }
        #if DEBUG
        trace("session.failure error=\(MobileLocalDirectFailureDiagnostic(error).kind)")
        #endif
        inputBuffer.clear(); utf8Tail.removeAll(); ownsLocalPrimaryScroll = false
        if case MobileShellConnectionError.rpcError("detached", _) = error { state = .detached }
        else { state = .failed }
    }
    private func sendViewport() {
        guard mounted, subscribed, canApplyOutput, viewport != nil, viewportTask == nil else { return }
        let token = epoch
        viewportTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token { self.viewportTask = nil } }
            while self.current(token), self.canApplyOutput, let report = self.viewport {
                do {
                    #if DEBUG
                    self.trace("viewport.request generation=\(report.2) cols=\(report.0.columns) rows=\(report.0.rows)")
                    #endif
                    let data = try await self.request("mobile.terminal.viewport", self.viewportParameters.report(
                        workspaceID: self.workspaceID, surfaceID: self.surfaceID, viewport: report.0, generation: report.2))
                    guard self.current(token), self.canApplyOutput else { return }
                    guard self.viewport?.2 == report.2 else { continue }
                    let response = try MobileTerminalViewportResponse.decode(data)
                    guard let grid = response.effectiveGrid, grid.columns <= 1000, grid.rows <= 1000 else {
                        throw MobileShellConnectionError.invalidResponse
                    }
                    #if DEBUG
                    self.trace("viewport.response generation=\(report.2) cols=\(grid.columns) rows=\(grid.rows)")
                    #endif
                    self.effectiveGrid = .init(columns: grid.columns, rows: grid.rows); self.viewportPending = false
                    if let epoch = response.renderEpoch, let floor = response.renderRevisionFloor { self.viewportFloor = (epoch, floor) }
                    self.confirm?(grid.columns, grid.rows, self.viewport?.1 ?? report.1)
                    guard self.current(token), self.canApplyOutput else { return }
                    // Confirmation can synchronously publish a newer natural layout.
                    guard self.viewport?.2 == report.2 else { continue }
                    self.requestReplay(); return
                } catch { self.fail(error, token: token); return }
            }
        }
    }
    private func receive(_ event: MobileEventEnvelope) {
        guard let data = event.payloadJSON, data.count <= 8 * 1024 * 1024 else { return }
        if let id = event.streamID, id != streamID { return }
        if event.topic != "terminal.render_grid" {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let surface = object["surface_id"] as? String, surface.caseInsensitiveCompare(surfaceID) == .orderedSame,
                  (object["client_id"] as? String).map({ $0 == clientID }) ?? true else { return }
            if event.topic == "mobile.terminal.detached" {
                state = .detached; ownsLocalPrimaryScroll = false; resetInputStream()
                gestureTask?.cancel(); gestureTask = nil; gestures.removeAll()
                outputTask?.cancel(); outputTask = nil; pendingFrames.removeAll(); pendingBytes = 0
            } else if let event = try? MobileTerminalSizeStateEvent.decode(data), event.state.generation > sizeStateGeneration {
                sizeStateGeneration = event.state.generation
                if event.state.cols != effectiveGrid?.columns || event.state.rows != effectiveGrid?.rows { requestReplay() }
            }
            return
        }
        guard state != .detached, state != .incompatible, state != .failed else { return }
        if pendingFrames.count >= 32 || pendingBytes + data.count > 8 * 1024 * 1024 {
            pendingFrames.removeAll(); pendingBytes = 0; requestReplay(); return
        }
        pendingFrames.append(data); pendingBytes += data.count; scheduleOutput()
    }
}

// Output draining shares the session's owner and epoch; it does not create a second lifecycle.
extension MobileLocalDirectTerminalSession {
    private func scheduleOutput() {
        guard current(epoch), subscribed, !viewportPending, effectiveGrid != nil,
              state != .detached, state != .incompatible, state != .failed, outputTask == nil else { return }
        let token = epoch
        outputGeneration &+= 1
        let generation = outputGeneration
        outputTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token, self.outputGeneration == generation { self.outputTask = nil } }
            await self.drainOutput(token: token)
        }
    }

    private func drainOutput(token: UInt64) async {
        while current(token), !viewportPending, canApplyOutput {
            let replay = needsReplay
            if !replay && pendingFrames.isEmpty { return }
            do {
                if !(try await processNextOutput(replay: replay, token: token)) { return }
            } catch {
                guard current(token) else { return }
                if case MobileShellConnectionError.rpcError("viewport_transition", _) = error, repairFailures < 3 {
                    repairFailures += 1; needsReplay = true
                    try? await Task.sleep(for: .milliseconds(100 * repairFailures))
                } else { fail(error, token: token); return }
            }
        }
    }

    private func nextOutputData(replay: Bool) async throws -> Data {
        if !replay {
            let data = pendingFrames.removeFirst(); pendingBytes -= data.count
            return data
        }
        needsReplay = false
        var params = targetParameters.merging(viewportParameters.replay(viewport: viewport?.0,
            generation: viewport?.2)) { _, new in new }
        params["anchor"] = "screen"
        params["max_scrollback_rows"] = hydrated ? 0 : MobileTerminalScrollbackPreference.resolve()
        let method = reattachRequested ? "mobile.terminal.reattach" : "mobile.terminal.replay"
        reattachRequested = false
        #if DEBUG
        trace("replay.request")
        #endif
        let data = try await request(method, params)
        #if DEBUG
        trace("replay.complete")
        #endif
        return data
    }

    private func processNextOutput(replay: Bool, token: UInt64) async throws -> Bool {
        let viewportGeneration = viewport?.2
        let data = try await nextOutputData(replay: replay)
        let workspace = workspaceID, surface = surfaceID
        let decoding = Task.detached {
            try MobileLocalDirectTerminalFrame.decode(data, workspaceID: workspace, surfaceID: surface, replay: replay)
        }
        let decoded = try await withTaskCancellationHandler {
            try await decoding.value
        } onCancel: { decoding.cancel() }
        #if DEBUG
        trace("decode.complete present=\(decoded != nil)")
        #endif
        guard current(token), canApplyOutput else { return false }
        guard viewport?.2 == viewportGeneration, !viewportPending else { needsReplay = true; return true }
        guard let decoded else {
            if replay { throw MobileShellConnectionError.invalidResponse }
            return true
        }
        return await deliver(decoded, replay: replay, token: token, viewportGeneration: viewportGeneration)
    }

    private func requireRepair(failure: State) -> Bool {
        repairFailures += 1
        guard repairFailures <= 2 else { state = failure; ownsLocalPrimaryScroll = false; return false }
        needsReplay = true; state = .loading
        return true
    }

    private func deliver(_ decoded: MobileLocalDirectTerminalFrame, replay: Bool, token: UInt64,
                         viewportGeneration: UInt64?) async -> Bool {
        if let floor = viewportFloor, decoded.frame.renderEpoch == floor.0, decoded.frame.renderRevision <= floor.1 {
            return replay ? requireRepair(failure: .incompatible) : true
        }
        let classification = MobileLocalDirectTerminalFrame.classify(decoded.frame, delivered: delivered)
        #if DEBUG
        trace("classify.\(classification)")
        #endif
        switch classification {
        case .stale: return replay ? requireRepair(failure: .incompatible) : true
        case .chainBreak: return requireRepair(failure: .incompatible)
        case .admit: break
        }
        #if DEBUG
        trace("apply.begin")
        #endif
        guard let apply else { return requireRepair(failure: .failed) }
        let applied = await apply(decoded.frame, decoded.bytes)
        #if DEBUG
        trace("apply.complete success=\(applied)")
        #endif
        guard applied else { return requireRepair(failure: .failed) }
        guard current(token), canApplyOutput else { return false }
        guard viewport?.2 == viewportGeneration, !viewportPending else { needsReplay = true; return true }
        delivered = decoded.frame; hydrated = true
        effectiveGrid = .init(columns: decoded.frame.columns, rows: decoded.frame.rows)
        ownsLocalPrimaryScroll = decoded.frame.activeScreen == .primary
        #if DEBUG
        trace("delivery.complete ready=\(!needsReplay)")
        #endif
        state = needsReplay ? .loading : .ready
        if !replay { repairFailures = 0 }
        return true
    }

    private func enqueueGesture(_ method: String, _ fields: [String: Any]) {
        guard state == .ready, current(epoch), !viewportPending else { return }
        guard gestures.count < 16 else { stopInput(); return }
        if method == "mobile.terminal.scroll", let last = gestures.last, last.0 == method {
            var merged = fields
            merged["delta_lines"] = max(-1000, min(1000, (last.1["delta_lines"] as? Double ?? 0) + (fields["delta_lines"] as? Double ?? 0)))
            gestures[gestures.count - 1] = (method, merged)
        } else { gestures.append((method, fields)) }
        guard gestureTask == nil else { return }
        let token = epoch
        gestureGeneration &+= 1
        let generation = gestureGeneration
        gestureTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token, self.gestureGeneration == generation { self.gestureTask = nil } }
            while self.current(token), self.state == .ready, !self.gestures.isEmpty {
                let next = self.gestures.removeFirst()
                do { _ = try await self.request(next.0, self.targetParameters.merging(next.1) { _, new in new }) }
                catch { self.fail(error, token: token); return }
            }
            if self.epoch == token, self.gestureGeneration == generation { self.gestures.removeAll() }
        }
    }
}
