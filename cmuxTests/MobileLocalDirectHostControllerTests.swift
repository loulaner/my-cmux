import Foundation
import CMUXMobileCore
import Observation
@testable import CmuxMobileTransport
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileLocalDirectHostControllerTests {
    @Test func enabledRequiresCanonicalPeerAddress() {
        var config = MobileLocalDirectHostConfiguration.initial()
        config.enabled = true
        #expect(throws: (any Error).self) { try config.validate() }
        config.address = "100.100.100.100"
        #expect(throws: (any Error).self) { try config.validate() }
        config.address = "100.70.1.2"
        #expect(throws: Never.self) { try config.validate() }
    }
    private func temporaryDirectory() throws -> URL {
        // Foundation preserves /var even after resolvingSymlinksInPath on macOS;
        // use the real private temp directory because the store rejects all symlink ancestors.
        let url = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("cmux-direct-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func durableIdentityPermissionsAndCorruption() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = CmxLocalDeviceFileStorage(baseURL: directory)
        let store = MobileLocalDirectConfigurationStore(files: files)
        let first = try await store.load()
        #expect(!first.enabled && first.address == nil && first.port == 49443)
        let disk = try Data(contentsOf: directory.appendingPathComponent("host-v1.json"))
        let json = try #require(JSONSerialization.jsonObject(with: disk) as? [String: Any])
        #expect(json["address"] is NSNull)
        #expect(try await MobileLocalDirectConfigurationStore(files: files).load() == first)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("host-v1.json").path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("host-v1.json"))
        await #expect(throws: (any Error).self) { try await MobileLocalDirectConfigurationStore(files: files).load() }
        #expect(try Data(contentsOf: directory.appendingPathComponent("host-v1.json")) == Data("broken".utf8))
    }

    @Test func symlinksCannotEscapeStorage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        let base = directory.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("host-v1.json"), withDestinationURL: outside)
        let files = CmxLocalDeviceFileStorage(baseURL: base)
        await #expect(throws: (any Error).self) { try await files.readConfiguration() }
        await #expect(throws: (any Error).self) { try await files.writeConfiguration(Data()) }
        #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
    }

    @Test func controllerOptInApprovalAndStop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try MobileLocalDirectHostController(baseURL: directory, policyDisabled: { false },
            listenerFactory: { _, handler in CmxLocalTCPListener(configuration: .loopbackForTesting(), onUnauthenticatedConnection: handler) })
        #expect(controller.configuration == nil)
        await controller.restoreIfEnabled()
        #expect(controller.state == .stopped)
        await controller.apply(address: "100.70.1.2", port: "49443", enabled: true)
        guard case .listening = controller.state else { Issue.record("Explicit enable failed"); return }
        #expect(!(await controller.requestApproval("No window")))
        let view = UUID()
        controller.viewOpened(view)
        controller.openPairingWindow()
        let pending = await beginApproval(controller)
        #expect(controller.pendingApproval == "Tablet")
        #expect(!(await controller.requestApproval("Second")))
        controller.resolveApproval(true)
        #expect(await pending.value)
        let refused = await beginApproval(controller)
        controller.viewClosed(view)
        #expect(!(await refused.value))
        #expect(!controller.allowsPairing)
        await controller.stop()
        #expect(controller.state == .stopped)
        let reopened = try MobileLocalDirectHostController(baseURL: directory, policyDisabled: { true })
        await reopened.restoreIfEnabled()
        #expect(reopened.configuration?.hostID == controller.configuration?.hostID)
        #expect(reopened.state == .failed)
        await reopened.stop()
    }


    @Test func approvalDeadlineAndCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = CloudCommandDeadlineClock()
        let controller = try MobileLocalDirectHostController(baseURL: directory, policyDisabled: { false }, clock: clock,
            listenerFactory: { _, handler in CmxLocalTCPListener(configuration: .loopbackForTesting(), onUnauthenticatedConnection: handler) })
        await controller.load()
        await controller.apply(address: "100.70.1.2", port: "49443", enabled: true)
        let view = UUID()
        controller.viewOpened(view)
        controller.openPairingWindow()
        await clock.waitUntilSleeping()
        let pending = await beginApproval(controller)
        clock.advance(by: .seconds(60))
        #expect(!(await pending.value))
        #expect(!controller.allowsPairing)
        controller.openPairingWindow()
        let cancelled = await beginApproval(controller)
        cancelled.cancel()
        #expect(!(await cancelled.value))
        #expect(controller.pendingApproval == nil)
        controller.closePairingWindow()
        controller.openPairingWindow()
        let stopped = await beginApproval(controller)
        await controller.stop()
        #expect(!(await stopped.value))
        controller.viewClosed(view)
    }

    @Test func occupiedPortReportsFailedWithoutFallback() async throws {
        let occupied = CmxLocalTCPListener(configuration: .loopbackForTesting()) { _ in }
        await occupied.start()
        guard case let .listening(_, port) = await occupied.state else { Issue.record("Test listener unavailable"); return }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try MobileLocalDirectHostController(baseURL: directory, policyDisabled: { false },
            listenerFactory: { _, handler in CmxLocalTCPListener(configuration: .loopbackForTesting(port: port), onUnauthenticatedConnection: handler) })
        await controller.load()
        await controller.apply(address: "100.70.1.2", port: "49443", enabled: true)
        #expect(controller.state == .failed)
        #expect(controller.hasError)
        await controller.stop()
        await occupied.stop()
    }

    @Test func controllerPairRPCAndIdleRevocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try MobileLocalDirectHostController(baseURL: directory, policyDisabled: { false },
            listenerFactory: { _, handler in CmxLocalTCPListener(configuration: .loopbackForTesting(), onUnauthenticatedConnection: handler) })
        await controller.load()
        await controller.apply(address: "100.70.1.2", port: "49443", enabled: true)
        guard case let .listening(address, port) = controller.state else { Issue.record("No listener"); return }
        let view = UUID()
        controller.viewOpened(view)
        controller.openPairingWindow()
        let raw = try CmxNetworkByteTransport(host: address, port: port)
        try await raw.connect()
        var pairing: Task<CmxLocalDirectAdmission.ClientAccepted, any Error>!
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = controller.pendingApproval } onChange: { continuation.resume() }
            pairing = Task { try await CmxLocalDirectAdmission.pair(displayName: "Synthetic iPad", transport: raw) }
        }
        #expect(controller.pendingApproval == "Synthetic iPad")
        #expect(await controller.credentials.devices().isEmpty)
        controller.resolveApproval(true)
        let admitted = try await pairing.value
        let payload = Data(#"{"id":"local","method":"mobile.host.status","params":{}}"#.utf8)
        try await admitted.transport.send(MobileSyncFrameCodec.encodeFrame(payload))
        var buffer = Data()
        var response: Data?
        while response == nil, let chunk = try await admitted.transport.receive() {
            buffer.append(chunk)
            response = try MobileSyncFrameCodec.decodeFrames(from: &buffer, maximumDecodedFrameCount: 1).first
        }
        let responseBytes = try #require(response)
        let json = try #require(JSONSerialization.jsonObject(with: responseBytes) as? [String: Any])
        let status = try #require(json["result"] as? [String: Any])
        #expect(status["mac_device_id"] as? String == controller.configuration?.hostID)
        #expect(controller.devices.count == 1)
        await controller.removeDevice(admitted.deviceID)
        #expect(controller.devices.isEmpty)
        #expect(controller.registry.count == 0)
        #expect(try await admitted.transport.receive() == nil)
        await admitted.transport.close()
        await controller.stop()
        controller.viewClosed(view)
    }

    private func beginApproval(_ controller: MobileLocalDirectHostController) async -> Task<Bool, Never> {
        var task: Task<Bool, Never>!
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = controller.pendingApproval } onChange: { continuation.resume() }
            task = Task { await controller.requestApproval("Tablet") }
        }
        return task
    }

}
