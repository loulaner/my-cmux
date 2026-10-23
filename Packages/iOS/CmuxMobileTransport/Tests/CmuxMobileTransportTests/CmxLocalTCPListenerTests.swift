import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite(.timeLimit(.minutes(1)))
struct CmxLocalTCPListenerTests {
    @Test(arguments: ["127.0.0.1", "0.0.0.0", "::", "100.63.0.1", "100.128.0.1",
        "100.064.0.1", "100.64.0.1.", "100.64.0.1:9", "host", " 100.64.0.1"])
    func rejectsInvalidAddress(address: String) {
        #expect(throws: CmxLocalTCPListenerConfiguration.ValidationError.invalidAddress) {
            try CmxLocalTCPListenerConfiguration(address: address, port: 1234)
        }
    }

    @Test func validatesPortAndRange() throws {
        for port in [0, -1, 65536] {
            #expect(throws: CmxLocalTCPListenerConfiguration.ValidationError.invalidPort) {
                try CmxLocalTCPListenerConfiguration(address: "100.64.0.1", port: port)
            }
        }
        #expect(try CmxLocalTCPListenerConfiguration(address: "100.127.255.255", port: 65535).port == 65535)
    }
    @Test func realLoopbackBytesAndPortOwnership() async throws {
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            do {
                let data = try await stream.receive()
                #expect(data == Data("ping".utf8))
                try await stream.send(Data("pong".utf8))
            } catch { Issue.record(error) }
        }
        await listener.start()
        guard case let .listening(address, port) = await listener.state else {
            Issue.record("Expected ready listener"); return
        }
        #expect(address == "127.0.0.1")
        #if os(macOS)
        // Inspect this test process only, at the actual listener port. A second
        // IPv4/IPv6 wildcard listener would appear as another name entry.
        let sockets = Process()
        sockets.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        sockets.arguments = ["-n", "-P", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier),
            "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let output = Pipe()
        sockets.standardOutput = output
        try sockets.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        sockets.waitUntilExit()
        #expect(sockets.terminationStatus == 0)
        let names = String(decoding: bytes, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }
        #expect(names == [Substring("n127.0.0.1:\(port)")])
        print("Native listener socket evidence: \(names)")
        #endif
        await listener.start()
        #expect(await listener.state == .listening(address: address, port: port))
        let occupied = CmxLocalTCPListener(configuration: .loopbackForTesting(port: port)) { _ in
            Issue.record("Conflicting listener must not accept")
        }
        await occupied.start()
        #expect(await occupied.state == .failed)
        let client = try CmxNetworkByteTransport(host: address, port: port)
        try await client.connect()
        try await client.send(Data("ping".utf8))
        #expect(try await client.receive() == Data("pong".utf8))
        #expect(try await client.receive() == nil)
        await client.close()
        await listener.stop()
        await occupied.stop()
        #expect(await listener.state == .stopped)
    }

    @Test func stopClosesActiveConnectionAndStartupWaiters() async throws {
        let (accepted, events) = AsyncStream<Bool>.makeStream()
        defer { events.finish() }
        let listener = CmxLocalTCPListener(configuration: .loopbackForTesting()) { stream in
            events.yield(true)
            _ = try? await stream.receive()
        }
        async let first: Void = listener.start()
        async let second: Void = listener.start()
        _ = await (first, second)
        guard case let .listening(address, port) = await listener.state else {
            Issue.record("Expected listener"); return
        }
        let client = try CmxNetworkByteTransport(host: address, port: port)
        try await client.connect()
        var iterator = accepted.makeAsyncIterator()
        #expect(await iterator.next() == true)
        await listener.stop()
        #expect(try await client.receive() == nil)
        await client.close()
        await listener.stop()
        #expect(await listener.state == .stopped)
        async let restarting: Void = listener.start()
        await listener.stop()
        _ = await restarting
        // A concurrent start may linearize after stop; explicitly stop that generation too.
        await listener.stop()
        #expect(await listener.state == .stopped)
    }

}
