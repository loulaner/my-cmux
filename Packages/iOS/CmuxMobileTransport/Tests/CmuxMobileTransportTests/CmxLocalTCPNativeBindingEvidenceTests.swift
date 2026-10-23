#if os(macOS)
import Foundation
@preconcurrency import Network
import Testing
@testable import CmuxMobileTransport

/// Opt-in local-only system evidence; never runs against a user's VPN in normal suites.
struct CmxLocalTCPNativeBindingEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_LOCAL_VPN_EVIDENCE_DIR"] != nil))
    func publicListenerOnActualLocalVPN() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CMUX_LOCAL_VPN_EVIDENCE_DIR"]))
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("vpn-candidates.private.json"))) as? [[String: String]])
        let row = try #require(rows.count == 1 ? rows.first : nil)
        let address = try #require(row["address"])
        let monitor = NWPathMonitor()
        let (paths, continuation) = AsyncStream<NWPath>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in continuation.yield(path) }
        monitor.start(queue: DispatchQueue(label: "cmux.local-vpn-evidence"))
        defer { monitor.cancel(); continuation.finish() }
        let path = try await CmxLocalDirectDeadline<NWPath>().run(timeout: .seconds(10), clock: ContinuousClock()) {
            var iterator = paths.makeAsyncIterator()
            guard let path = await iterator.next() else { throw CmxLocalDirectAdmission.Failure.denied }
            return path
        }
        let evidence = "status=\(path.status)\ninterfaces=\(path.availableInterfaces.map { "\($0.name):\($0.index):\($0.type)" })\n"
        try evidence.write(to: directory.appendingPathComponent("monitor.private.log"), atomically: true, encoding: .utf8)
        let listener = CmxLocalTCPListener(configuration: try .init(address: address, port: 48993)) { stream in
            await stream.close() // Never approve or dispatch any externally arriving connection.
        }
        await listener.start()
        let state = await listener.state
        try String(describing: state).write(to: directory.appendingPathComponent("listener-state.private.log"), atomically: true, encoding: .utf8)
        let beforeStop = try sockets()
        try beforeStop.write(to: directory.appendingPathComponent("sockets-before-stop.private.log"), atomically: true, encoding: .utf8)
        await listener.stop()
        let afterStop = try sockets()
        try afterStop.write(to: directory.appendingPathComponent("sockets-after-stop.private.log"), atomically: true, encoding: .utf8)
        #expect(state == .listening(address: address, port: 48993))
        #expect(beforeStop.contains("n\(address):48993"))
        #expect(!beforeStop.contains("n*:48993"))
        #expect(!afterStop.contains(":48993"))
        #expect(await listener.state == .stopped)
    }

    private func sockets() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 || process.terminationStatus == 1)
        return String(decoding: bytes, as: UTF8.self)
    }
}

#endif
