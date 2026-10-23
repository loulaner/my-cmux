import Foundation
import CMUXMobileCore
import Testing
@testable import CmuxMobileTransport

struct CmxLocalDirectClientFailureTests {
    @Test(arguments: [AdmissionFailureTransport.Mode.sendLost, .readLost, .eof, .empty, .malformed, .oversized, .denied, .cancel])
    func clientFailureClassification(mode: AdmissionFailureTransport.Mode) async {
        let stream = AdmissionFailureTransport(mode)
        do {
            _ = try await CmxLocalDirectAdmission.authenticate(deviceID: "00000000-0000-0000-0000-000000000001",
                token: Data(repeating: 42, count: 32), transport: stream)
            Issue.record("Unexpected success")
        } catch {
            let expected: String
            switch mode {
            case .sendLost, .readLost, .eof, .empty: expected = "connectionLost"
            case .malformed, .oversized: expected = "invalidResponse"
            case .denied: expected = "denied"
            default: expected = "cancel"
            }
            if expected == "cancel" { #expect(error is CancellationError) }
            else { #expect(String(describing: error) == expected) }
        }
        #expect(await stream.closed)
    }
    @Test func deadlinePreservesOperationError() async {
        do {
            _ = try await CmxLocalDirectDeadline<Int>().run(timeout: .seconds(1), clock: ContinuousClock()) {
                throw AdmissionFailureTransport.Offline.disconnected
            }
            Issue.record("Unexpected success")
        } catch { #expect(error is AdmissionFailureTransport.Offline) }
    }
    @Test func exchangeTimeoutAndCancellationAreDistinct() async {
        let stream = AdmissionFailureTransport(.blocked)
        do {
            _ = try await CmxLocalDirectAdmission.exchange(.init(operation: "authenticate", deviceID: "00000000-0000-0000-0000-000000000001",
                token: Data(repeating: 42, count: 32).base64EncodedString()), transport: stream,
                expectedStatus: "authenticated", timeout: .zero)
            Issue.record("Unexpected success")
        } catch { #expect(String(describing: error) == "timedOut") }
        #expect(await stream.closed)
        let cancelled = AdmissionFailureTransport(.blocked)
        let task = Task {
            try await CmxLocalDirectAdmission.pair(displayName: "Synthetic tablet", transport: cancelled)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Unexpected success") }
        catch { #expect(error is CancellationError) }
        #expect(await cancelled.closed)
    }

    @Test(arguments: ["version", "extra", "identity", "status", "token", "oversizeChunk"])
    func completeInvalidResponsesNeverBecomeNetworkErrors(_ kind: String) async throws {
        var response: [String: Any] = ["version": 1, "status": "authenticated", "deviceID": "00000000-0000-0000-0000-000000000001"]
        switch kind {
        case "version": response["version"] = 2
        case "extra": response["extra"] = true
        case "identity": response["deviceID"] = "00000000-0000-0000-0000-000000000002"
        case "status": response["status"] = "unknown"
        case "token": response = ["version": 1, "status": "paired", "deviceID": "00000000-0000-0000-0000-000000000001", "token": "invalid"]
        default: break
        }
        let bytes = kind == "oversizeChunk" ? Data(repeating: 0, count: 65537)
            : try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: response))
        let stream = LocalDirectScriptedTransport(chunks: [bytes])
        do {
            if kind == "token" { _ = try await CmxLocalDirectAdmission.pair(displayName: "Synthetic tablet", transport: stream) }
            else { _ = try await CmxLocalDirectAdmission.authenticate(deviceID: "00000000-0000-0000-0000-000000000001",
                token: Data(repeating: 42, count: 32), transport: stream) }
            Issue.record("Unexpected success")
        } catch { #expect(String(describing: error) == "invalidResponse") }
        #expect(await stream.closed)
    }
    @Test func serverEOFStillUsesDenialWireContract() async throws {
        let store = try CmxLocalDeviceCredentialStore(storage: LocalDeviceMemoryStorage(), storageScope: "failure-classification")
        try await store.load()
        let server = CmxLocalDirectAdmission(store: store, approval: { _ in Issue.record("Must not approve EOF"); return false }, isCurrent: { true })
        let stream = LocalDirectScriptedTransport(chunks: [])
        do { _ = try await server.accept(stream); Issue.record("Unexpected success") }
        catch { #expect(String(describing: error) == "denied") }
        #expect(await stream.closed)
        var bytes = try #require(await stream.sent.first)
        let frames = try MobileSyncFrameCodec.decodeFrames(from: &bytes)
        let response = try #require(frames.first)
        #expect(try JSONSerialization.jsonObject(with: response) as? [String: AnyHashable] == ["version": 1, "status": "denied"])
    }

    @Test(arguments: ["name", "id", "token"])
    func invalidLocalRequestSendsNothing(_ field: String) async {
        let stream = LocalDirectScriptedTransport(chunks: [])
        do {
            if field == "name" { _ = try await CmxLocalDirectAdmission.pair(displayName: "", transport: stream) }
            else { _ = try await CmxLocalDirectAdmission.authenticate(deviceID: field == "id" ? "invalid" : "00000000-0000-0000-0000-000000000001",
                token: Data(repeating: 42, count: field == "token" ? 31 : 32), transport: stream) }
            Issue.record("Unexpected success")
        } catch { #expect(String(describing: error) == "denied") }
        #expect(await stream.sent.isEmpty)
        #expect(await stream.closed)
    }
    @Test func serverCancellationStillDeniesAndCloses() async throws {
        let store = try CmxLocalDeviceCredentialStore(storage: LocalDeviceMemoryStorage(), storageScope: "server-cancellation")
        try await store.load()
        let started = AsyncStream<Bool>.makeStream()
        let blocked = AsyncStream<Bool>.makeStream()
        defer { started.continuation.finish(); blocked.continuation.finish() }
        let server = CmxLocalDirectAdmission(store: store, approval: { _ in
            started.continuation.yield(true)
            for await value in blocked.stream { return value }
            return false
        }, isCurrent: { true })
        let stream = LocalDirectScriptedTransport(chunks: [try CmxLocalDirectWire(operation: "pair", displayName: "Synthetic tablet").framed()])
        let task = Task { try await server.accept(stream) }
        var iterator = started.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        task.cancel()
        do { _ = try await task.value; Issue.record("Unexpected success") }
        catch { #expect(String(describing: error) == "denied") }
        #expect(await stream.closed)
        #expect(await store.devices().isEmpty)
    }

}
