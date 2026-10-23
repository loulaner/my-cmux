import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite(.timeLimit(.minutes(1)))
struct MobileLocalDirectRPCClientTests {
    private func request(_ id: String) -> Data { Data("{\"id\":\"\(id)\",\"method\":\"workspace.list\",\"params\":{}}".utf8) }
    private func result(_ data: Data) throws -> String? {
        (try JSONSerialization.jsonObject(with: data) as? [String: String])?["value"]
    }

    @Test func usesSessionResultAndNeverAugmentsAuth() async throws {
        let transport = LocalDirectRPCTransport()
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        #expect(await transport.connects == 0)
        let stream = await client.subscribe(to: ["workspace.updated"])
        #expect(await transport.connects == 0)
        let one = Task { try await client.sendRequest(request("one")) }
        let two = Task { try await client.sendRequest(request("two")) }
        var writes = transport.writes.stream.makeAsyncIterator()
        for _ in 0..<2 {
            let wire = try #require(await writes.next())
            let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            #expect(Set(object.keys) == ["id", "method", "params"])
        }
        try await transport.deliverJSON(#"{"id":"two","ok":true,"result":{"value":"second"}}"#)
        try await transport.deliverJSON(#"{"kind":"event","topic":"workspace.updated","payload":{"value":1}}"#)
        try await transport.deliverJSON(#"{"id":"one","ok":true,"result":{"value":"first"}}"#)
        #expect(try result(await one.value) == "first")
        #expect(try result(await two.value) == "second")
        var events = stream.makeAsyncIterator()
        #expect(await events.next()?.topic == "workspace.updated")
        await client.disconnect()
        await client.disconnect()
        #expect(await events.next() == nil)
        #expect(await transport.connects == 1)
        #expect(await transport.closes == 1)
        await #expect(throws: MobileShellConnectionError.self) { try await client.sendRequest(request("three")) }
        #expect(await transport.connects == 1)
    }

    @Test(arguments: ["auth", "attach_token", "stack_access_token", "stack_refresh_token", "authorization", "token"])
    func rejectsLegacyCredentials(_ field: String) async throws {
        let transport = LocalDirectRPCTransport()
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        let data = try JSONSerialization.data(withJSONObject: ["id": "one", "method": "workspace.list", field: "secret"])
        await #expect(throws: MobileLocalDirectRPCClient.Failure.invalidRequest) { try await client.sendRequest(data) }
        #expect(await transport.connects == 0)
        await client.disconnect()
        #expect(await transport.closes == 1)
    }

    @Test(arguments: ["[]", "{}", "{\"method\":\"x\",\"id\":1}", "{\"method\":\"x\",\"id\":\"\"}", "bad"])
    func rejectsMalformedRequests(_ json: String) async {
        let transport = LocalDirectRPCTransport()
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        await #expect(throws: MobileLocalDirectRPCClient.Failure.invalidRequest) { try await client.sendRequest(Data(json.utf8)) }
        #expect(await transport.connects == 0)
        await client.disconnect()
    }

    @Test(arguments: ["unauthorized", "account_mismatch", "invalid_params"])
    func serverErrorUsesExistingDecoderWithoutRetry(_ code: String) async throws {
        let transport = LocalDirectRPCTransport()
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        let task = Task { try await client.sendRequest(request("error")) }
        var writes = transport.writes.stream.makeAsyncIterator()
        _ = await writes.next()
        try await transport.deliverJSON("{\"id\":\"error\",\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"denied\"}}")
        do { _ = try await task.value; Issue.record("Expected server error") }
        catch let error as MobileShellConnectionError {
            switch (code, error) {
            case ("unauthorized", .authorizationFailed("denied")), ("account_mismatch", .accountMismatch("denied")),
                 ("invalid_params", .rpcError("invalid_params", "denied")): break
            default: Issue.record("Unexpected mapping")
            }
        }
        await client.disconnect()
        #expect(await writes.next() == nil)
        #expect(await transport.connects == 1)
    }

    @Test(arguments: [false, true])
    func cancelledOrTimedOutRequestCannotConsumeNextResponse(timeout: Bool) async throws {
        let transport = LocalDirectRPCTransport()
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        let old = Task { try await client.sendRequest(request("old"), timeoutNanoseconds: timeout ? 30_000_000 : nil) }
        var writes = transport.writes.stream.makeAsyncIterator()
        _ = await writes.next()
        if !timeout { old.cancel() }
        do { _ = try await old.value; Issue.record("Expected cancellation or deadline") }
        catch is CancellationError { #expect(!timeout) }
        catch let error as MobileShellConnectionError {
            if case .requestTimedOut = error { #expect(timeout) } else { Issue.record(error) }
        }
        let next = Task { try await client.sendRequest(request("next")) }
        _ = await writes.next()
        try await transport.deliverJSON(#"{"id":"old","ok":true,"result":{"value":"late"}}"#)
        try await transport.deliverJSON(#"{"id":"next","ok":true,"result":{"value":"current"}}"#)
        #expect(try result(await next.value) == "current")
        await client.disconnect()
    }

    @Test func disconnectBeforeFirstUseClosesExactlyOnce() async {
        let transport = LocalDirectRPCTransport()
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        async let first: Void = client.disconnect()
        async let second: Void = client.disconnect()
        _ = await (first, second)
        #expect(await transport.connects == 0)
        #expect(await transport.closes == 1)
        let stream = await client.subscribe(to: ["workspace.updated"])
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
    @Test func remoteClosureCannotReclaimTheAdmittedTransport() async throws {
        let transport = LocalDirectRPCTransport(automatic: true)
        let client = MobileLocalDirectRPCClient(admittedTransport: transport)
        _ = try await client.sendRequest(request("first"))
        var writes = transport.writes.stream.makeAsyncIterator()
        _ = await writes.next()
        await transport.finishReceiving()
        #expect(await writes.next() == nil) // Reader teardown has closed the transport.
        await #expect(throws: MobileShellConnectionError.self) { try await client.sendRequest(request("later")) }
        #expect(await transport.connects == 1)
        await client.disconnect()
        #expect(await transport.closes == 1)
    }

}
