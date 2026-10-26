import CMUXMobileCore
@testable import CmuxMobileTransport
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct MobileLocalDirectSessionServerTests {
    @Test(arguments: ["workspace.create", "browser.open", "phone_push.keys.exchange", "mobile.attach_ticket.create", "feed.list"])
    func unlistedMethodsAreDenied(_ method: String) {
        let request = MobileHostRPCRequest(id: "test", method: method, params: [:], auth: nil)
        guard case let .failure(error) = MobileLocalDirectRPCPolicy().authorizationError(for: request) else {
            Issue.record("Local direct must reject unlisted method"); return
        }
        #expect(error.code == "method_not_found")
    }
    @Test func allowedMethodsAndTopicBoundary() {
        let policy = MobileLocalDirectRPCPolicy(workspaceChangesEnabled: false, fileTransferDisabled: false)
        for method in policy.methods where method != "mobile.events.subscribe" {
            #expect(policy.authorizationError(for: MobileHostRPCRequest(id: "test", method: method, params: [:], auth: nil)) == nil)
        }
        for topics in [["*"], ["terminal.bytes", "feed.changed"], ["browser.stream"], [""], []] {
            let request = MobileHostRPCRequest(id: "test", method: "mobile.events.subscribe", params: ["topics": topics], auth: nil)
            guard case let .failure(error) = policy.authorizationError(for: request) else { Issue.record("Invalid topic accepted"); continue }
            #expect(error.code == "invalid_params")
        }
        #expect(policy.authorizationError(for: MobileHostRPCRequest(id: "test", method: "mobile.events.subscribe",
            params: ["topics": Array(policy.topics)], auth: nil)) == nil)
    }

    @Test func isolatedHostContract() throws {
        let env = ProcessInfo.processInfo.environment
        #expect(Bundle.main.bundleIdentifier == "com.cmuxterm.app.debug.local-terminal-acceptance")
        let home = try #require(env["CMUX_LOCAL_ACCEPTANCE_HOME"])
        #expect(home.hasPrefix("/tmp/"))
        #expect(env["HOME"] == home)
        #expect(env["CFFIXED_USER_HOME"] == home)
        #expect(env["XDG_CONFIG_HOME"] == home + "/.config")
        #expect(Data(base64Encoded: env["CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64"] ?? "")?.count == 32)
        #expect(TestProcessDefaults.isolatedDomainName != nil)
    }

    @Test func directContextNeverCallsStackClosures() async throws {
        let store = try CmxLocalDeviceCredentialStore(storage: MobileLocalDirectMemoryStorage(), storageScope: "rpc-direct")
        try await store.load()
        let issued = try await store.issueDevice(displayName: "Synthetic tablet")
        let authorization = MobileHostConnectionAuthorizationContext.localDirect(issued.device)
        let request = MobileHostRPCRequest(id: "status", method: "mobile.host.status", params: [:], auth: nil)
        #expect(await MobileHostService.connectionAuthorizationError(for: request, authorization: authorization,
            stackAuthorization: { _ in Issue.record("Local auth must not call Stack"); return nil }) == nil)
        let result = await MobileHostService.connectionStatusResult(for: request, authorization: authorization,
            hostDeviceID: "synthetic-host", stackStatus: { _ in Issue.record("Local status must not call cloud"); return .ok([:]) })
        guard case let .ok(payload as [String: Any]) = result else { Issue.record("Expected local status"); return }
        #expect(payload["mac_device_id"] as? String == "synthetic-host")
        #expect(Set(payload["capabilities"] as? [String] ?? []) == Set(MobileLocalDirectRPCPolicy().capabilities))
        for key in ["phone_push", "account_scope", "mac_compatible_mac_tags", "mac_client_namespace"] { #expect(payload[key] == nil) }
        #expect((payload["routes"] as? [Any])?.isEmpty == true)
    }

    @Test func actualHandshakeAndMacDispatcherOverLoopback() async throws {
        let priorIdentity = MobileHostPublicStatusCache.currentV2DeviceID()
        MobileHostPublicStatusCache.updateV2DeviceID("synthetic-cloud-identity-must-not-leak")
        defer { MobileHostPublicStatusCache.updateV2DeviceID(priorIdentity) }
        let store = try CmxLocalDeviceCredentialStore(storage: MobileLocalDirectMemoryStorage(), storageScope: "rpc-loopback")
        try await store.load()
        let registry = MobileHostConnectionRegistry()
        let owner = MobileLocalDirectSessionServer(hostDeviceID: "synthetic-host", store: store,
            approval: { _ in true }, isCurrent: { true }, managedPolicyDisabled: { false }, registry: registry)
        let (exits, finish) = AsyncStream<Void>.makeStream()
        defer { finish.finish() }
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            await owner.serve(stream)
            finish.yield(())
        }
        await listener.start()
        guard case let .listening(address, port) = await listener.state else { Issue.record("Listener unavailable"); return }
        let raw = try CmxNetworkByteTransport(host: address, port: port)
        try await raw.connect()
        let admitted = try await CmxLocalDirectAdmission.pair(displayName: "Synthetic tablet", transport: raw)
        let status = try await rpc("mobile.host.status", transport: admitted.transport)
        let payload = try #require(status["result"] as? [String: Any])
        #expect(payload["mac_device_id"] as? String == "synthetic-host")
        #expect(Set(payload["capabilities"] as? [String] ?? []) == Set(MobileLocalDirectRPCPolicy().capabilities))
        #expect(payload["phone_push"] == nil)
        #expect(payload["mac_compatible_mac_tags"] == nil)
        let caps = try #require(payload["capabilities"] as? [String])
        #expect(caps.count == 10)
        #expect(!caps.contains(MobileTerminalInputFrame.capability))
        #expect(!caps.contains { $0.contains("iroh") || $0.contains("phone_push") || $0.contains("account_auth") })
        for method in ["workspace.create", "phone_push.keys.exchange", "browser.open", "mobile.sync.fetch"] {
            let response = try await rpc(method, transport: admitted.transport)
            #expect((response["error"] as? [String: Any])?["code"] as? String == "method_not_found")
        }
        let badTopics = try await rpc("mobile.events.subscribe", params: ["topics": ["terminal.bytes", "*"]], transport: admitted.transport)
        #expect((badTopics["error"] as? [String: Any])?["code"] as? String == "invalid_params")
        let subscription = try await rpc("mobile.events.subscribe",
            params: ["topics": ["terminal.bytes"], "stream_id": "synthetic-stream", "event_transport": "iroh_server_events_v1"],
            transport: admitted.transport)
        #expect((subscription["result"] as? [String: Any])?["event_transport"] as? String == "control_v1")
        _ = try await rpc("mobile.events.unsubscribe", params: ["stream_id": "synthetic-stream"], transport: admitted.transport)
        for method in ["workspace.list", "mobile.workspace.list"] {
            let workspaces = try await rpc(method, params: ["include_host_status": true], transport: admitted.transport)
            if let value = workspaces["result"] as? [String: Any] { #expect(value["host_status"] == nil) }
            else { Issue.record("Workspace list must return its ordinary result") }
        }
        _ = try await store.revoke(deviceID: admitted.deviceID)
        // A revoked request may get admission_expired or a closed stream, never business success.
        do {
            let response = try await rpc("mobile.host.status", transport: admitted.transport)
            #expect(response["result"] == nil)
        } catch {}
        await admitted.transport.close()
        await listener.stop()
        var iterator = exits.makeAsyncIterator()
        _ = await iterator.next()
        #expect(registry.count == 0)
    }

    @Test(arguments: ["epoch", "policy"])
    func staleAndPolicyDisabledNeverIssue(_ reason: String) async throws {
        let store = try CmxLocalDeviceCredentialStore(storage: MobileLocalDirectMemoryStorage(), storageScope: "rpc-denied")
        try await store.load()
        let owner = MobileLocalDirectSessionServer(hostDeviceID: "synthetic-host", store: store,
            approval: { _ in Issue.record("Must not ask for approval"); return true },
            isCurrent: { reason != "epoch" }, managedPolicyDisabled: { reason == "policy" }, registry: MobileHostConnectionRegistry())
        let transport = RecordingMobileHostByteTransport()
        await owner.serve(transport)
        #expect(await store.devices().isEmpty)
        #expect(await transport.observedCloseCount() > 0)
    }

    private func rpc(_ method: String, params: [String: Any] = [:], transport: any CmxByteTransport) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": "synthetic-request", "method": method, "params": params])
        try await transport.send(MobileSyncFrameCodec.encodeFrame(data))
        var buffer = Data()
        while let chunk = try await transport.receive() {
            buffer.append(chunk)
            if let frame = try MobileSyncFrameCodec.decodeFrames(from: &buffer, maximumDecodedFrameCount: 1).first {
                return try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            }
        }
        throw CmxLocalDirectAdmission.Failure.denied
    }

}
