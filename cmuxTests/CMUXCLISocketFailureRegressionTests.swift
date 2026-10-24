import Darwin
import Foundation
import Testing

private final class CMUXCLISocketFailureBundleToken {}

@Suite struct CMUXCLISocketFailureRegressionTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    @Test func staleSocketConnectRefusalKeepsOrdinaryError() throws {
        let cliPath = try bundledCLIPath()
        let root = URL(
            fileURLWithPath: "/tmp/cmux-sr-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("cmux.sock", isDirectory: false).path
        try createStaleSocketFile(at: socketPath)
        defer { unlink(socketPath) }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: isolatedEnvironment(socketPath: socketPath, root: root),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.lowercased().contains("connection refused"), Comment(rawValue: result.stdout))
    }

    @Test func missingSocketKeepsOrdinaryError() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-failure-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("missing.sock", isDirectory: false).path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: isolatedEnvironment(socketPath: socketPath, root: root),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.lowercased().contains("socket not found"), Comment(rawValue: result.stdout))
    }

    @Test func missingRelayMetadataFailsWithoutBlocking() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-failure-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = "127.0.0.1:\(try unusedRelayPort())"
        let environment = isolatedEnvironment(socketPath: socketPath, root: root)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 2
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("Missing relay auth metadata"), Comment(rawValue: result.stdout))
    }

    @Test func structuredProtocolCodeControlsOrdinaryError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-failure-structured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unavailableResult = try runStructuredError(
            code: "unavailable",

            root: root
        )
        #expect(!unavailableResult.timedOut, Comment(rawValue: unavailableResult.stdout))
        #expect(unavailableResult.status != 0, Comment(rawValue: unavailableResult.stdout))
        #expect(unavailableResult.stdout.lowercased().contains("unavailable"), Comment(rawValue: unavailableResult.stdout))

        let actionableResult = try runStructuredError(
            code: "internal_error",

            root: root
        )
        #expect(!actionableResult.timedOut, Comment(rawValue: actionableResult.stdout))
        #expect(actionableResult.status != 0, Comment(rawValue: actionableResult.stdout))
        #expect(
            actionableResult.stdout.contains("internal_error: TabManager not available"),
            Comment(rawValue: actionableResult.stdout)
        )
    }

    @Test func routineProtocolOutcomesKeepOrdinaryErrors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-failure-routine-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for code in ["invalid_params", "not_found", "protected", "tab_manager_unavailable"] {
            let result = try runStructuredError(
                code: code,

                root: root
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status != 0, Comment(rawValue: result.stdout))
            #expect(result.stdout.lowercased().contains(code), Comment(rawValue: result.stdout))
        }
    }

    @Test func localPiSurfaceUnavailableSentinelKeepsExit69() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-failure-pi-unavailable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let result = try runPiSurfaceUnavailable(
            surfaceID: surfaceID,

            root: root
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 69, Comment(rawValue: result.stdout))
        #expect(result.stdout.lowercased().contains("surface not found"), Comment(rawValue: result.stdout))
    }

    @Test func expectedAgentHookFailureDoesNotConsumeActionableThrottleSlot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-local-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "local-hook-shared"
        let expected = try runAgentHookError(message: "TabManager not available", root: root, sessionID: sessionID)
        #expect(!expected.timedOut, Comment(rawValue: expected.stdout))
        #expect(!hasLocalFailureSlot(root: root, sessionID: sessionID))
        let actionable = try runAgentHookError(message: "remote proxy failed: TabManager not available", root: root, sessionID: sessionID)
        #expect(!actionable.timedOut, Comment(rawValue: actionable.stdout))
        #expect(hasLocalFailureSlot(root: root, sessionID: sessionID))
    }

    @Test(arguments: [
        [String: String](),
        ["CMUX_CLI_SENTRY_DISABLED": "1"],
        ["CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1"],
        ["CMUX_BUNDLE_ID": "foreign.fixture"],
    ])
    func agentHookLifecycleClassificationKeepsActionableFailures(overrides: [String: String]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-local-matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try runAgentHookError(message: "TabManager not available", root: root, sessionID: "expected", overrides: overrides)
        #expect(!expected.timedOut, Comment(rawValue: expected.stdout))
        #expect(hasLocalFailureSlot(root: root, sessionID: "expected") == !overrides.isEmpty)
        let actionable = try runAgentHookError(message: "remote proxy failed: TabManager not available", root: root, sessionID: "actionable", overrides: overrides)
        #expect(!actionable.timedOut, Comment(rawValue: actionable.stdout))
        #expect(hasLocalFailureSlot(root: root, sessionID: "actionable"))
    }

    private func hasLocalFailureSlot(root: URL, sessionID: String) -> Bool {
        let path = root.appendingPathComponent("codex-hook-sessions.json")
        guard let data = try? Data(contentsOf: path),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = state["agentHookFailureReportTimestamps"] as? [String: Any] else { return false }
        return slots["codex:notification-delivery:\(sessionID)"] != nil
    }

    @Test func foreignBundleIdentityKeepsRelayAuthenticationError() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-failure-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = "127.0.0.1:\(try unusedRelayPort())"
        var environment = isolatedEnvironment(socketPath: socketPath, root: root)
        environment["CMUX_BUNDLE_ID"] = "mosaic.com.emergent.app"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 2
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("Missing relay auth metadata"), Comment(rawValue: result.stdout))
    }

    @Test func repeatedCommandTimeoutsKeepOrdinaryErrors() throws {
        let cliPath = try bundledCLIPath()
        let root = URL(
            fileURLWithPath: "/tmp/cmux-st-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A bound, listening socket that never accepts or replies: connect and
        // write succeed, the response read times out.
        let socketPath = root.appendingPathComponent("cmux.sock", isDirectory: false).path
        let listenerFD = try muteListeningSocketDescriptor(at: socketPath)
        defer {
            close(listenerFD)
            unlink(socketPath)
        }

        func runPing() -> ProcessRunResult {
            var environment = isolatedEnvironment(socketPath: socketPath, root: root)
            // Keep any incidental hook state inside the shared fixture root.
            environment["CMUX_CLAUDE_HOOK_STATE_PATH"] = root
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false).path
            return runProcess(
                executablePath: cliPath,
                arguments: ["ping"],
                environment: environment,
                timeout: 10
            )
        }

        let first = runPing()

        #expect(!first.timedOut, Comment(rawValue: first.stdout))
        #expect(first.status != 0, Comment(rawValue: first.stdout))
        #expect(first.stdout.contains("Command timed out"), Comment(rawValue: first.stdout))

        let second = runPing()

        #expect(!second.timedOut, Comment(rawValue: second.stdout))
        #expect(second.status != 0, Comment(rawValue: second.stdout))
        #expect(second.stdout.contains("Command timed out"), Comment(rawValue: second.stdout))
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CMUXCLISocketFailureBundleToken.self)
    }

    private func runStructuredError(
        code: String,

        root: URL
    ) throws -> ProcessRunResult {
        try runMockSocketProcess(
            arguments: ["capabilities"],

            root: root
        ) { line in
            guard let requestData = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  let id = request["id"] as? String else {
                return nil
            }
            let response: [String: Any] = [
                "id": id,
                "ok": false,
                "error": [
                    "code": code,
                    "message": code == "tab_manager_unavailable" ? "Unable to access the target workspace." : "TabManager not available"
                ]
            ]
            return try? String(
                data: JSONSerialization.data(withJSONObject: response),
                encoding: .utf8
            )
        }
    }

    private func runPiSurfaceUnavailable(
        surfaceID: String,

        root: URL
    ) throws -> ProcessRunResult {
        let inputData = try JSONSerialization.data(withJSONObject: [
            "session_id": "pi-failure-\(UUID().uuidString)",
            "hook_event_name": "PostToolUse",
            "cwd": root.path,
        ])
        let environmentOverrides = [
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "0",
        ]

        return try runMockSocketProcess(
            arguments: [
                "hooks", "pi", "post-tool-use",
                "--surface", surfaceID,
            ],
            root: root,
            stdinText: String(decoding: inputData, as: UTF8.self),
            environmentOverrides: environmentOverrides
        ) { line in
            guard let request = try? JSONSerialization.jsonObject(
                with: Data(line.utf8),
                options: []
            ) as? [String: Any],
                  let id = request["id"] as? String else {
                return nil
            }
            let response: [String: Any] = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "not_found",
                    "message": "No live delivery target",
                ],
            ]
            return try? String(
                data: JSONSerialization.data(withJSONObject: response),
                encoding: .utf8
            )
        }
    }

    private func runAgentHookError(
        message: String,

        root: URL,
        sessionID: String? = nil,
        overrides: [String: String] = [:]
    ) throws -> ProcessRunResult {
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let resolvedSessionID = sessionID ?? "local-hook-\(UUID().uuidString)"
        let transcriptURL = root.appendingPathComponent("rollout-\(resolvedSessionID).jsonl")
        try #"{"type":"session_meta","payload":{"id":"\#(resolvedSessionID)","source":"cli","originator":"codex-tui"}}"#
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let inputData = try JSONSerialization.data(withJSONObject: [
            "session_id": resolvedSessionID,
            "turn_id": UUID().uuidString,
            "hook_event_name": "Stop",
            "cwd": root.path,
            "transcript_path": transcriptURL.path,
            "last_assistant_message": "done"
        ])
        let input = String(decoding: inputData, as: UTF8.self)

        var environmentOverrides = [
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "0",
        ]

        environmentOverrides.merge(overrides, uniquingKeysWith: { _, new in new })
        return try runMockSocketProcess(
            arguments: [
                "hooks", "codex", "stop",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            root: root,
            stdinText: input,
            environmentOverrides: environmentOverrides
        ) { line in
            if line.hasPrefix("notify_target_async ") || AgentHookTestNotificationPipeline.candidatePresentation(line) != nil {
                return "ERROR: \(message)"
            }
            guard let request = try? JSONSerialization.jsonObject(
                with: Data(line.utf8),
                options: []
            ) as? [String: Any],
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return "OK"
            }
            switch method {
            case "agent.resolve_delivery_target":
                return try? String(
                    data: JSONSerialization.data(withJSONObject: [
                        "id": id, "ok": false,
                        "error": ["code": "unrecognized_method", "message": "process resolution unavailable in fixture"],
                    ]),
                    encoding: .utf8
                )
            case "surface.list":
                return try? String(
                    data: JSONSerialization.data(withJSONObject: [
                        "id": id,
                        "ok": true,
                        "result": [
                            "surfaces": [[
                                "id": surfaceID,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true,
                            ]]
                        ]
                    ]),
                    encoding: .utf8
                )
            default:
                return try? String(
                    data: JSONSerialization.data(withJSONObject: [
                        "id": id,
                        "ok": true,
                        "result": [:] as [String: Any],
                    ]),
                    encoding: .utf8
                )
            }
        }
    }

    private func runMockSocketProcess(
        arguments: [String],

        root: URL,
        stdinText: String? = nil,
        environmentOverrides: [String: String] = [:],
        respond: @escaping @Sendable (String) -> String?
    ) throws -> ProcessRunResult {
        let socketPath = "/tmp/cmux-structured-\(UUID().uuidString.prefix(8)).sock"
        let listenerFD = try bindUnixSocket(at: socketPath)
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD, respond: respond)
            },
            onListenerClosed: {}
        )
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = BundledCLITestSupport.hermeticCLIEnvironment(home: root)
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = "com.loulaner.mycmux.debug.cli-failure-fixture"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "0"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "1"
        environment.merge(environmentOverrides, uniquingKeysWith: { _, new in new })
        return runProcess(
            executablePath: try bundledCLIPath(),
            arguments: arguments,
            environment: environment,
            timeout: 5,
            stdinText: stdinText
        )
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            let errorCode = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        return fd
    }

    private func isolatedEnvironment(socketPath: String, root: URL) -> [String: String] {
        var environment = BundledCLITestSupport.hermeticCLIEnvironment(home: root)
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"
        return environment
    }

    private func unusedRelayPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket failed")
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw posixError("bind failed")
        }
        guard listen(fd, 1) == 0 else {
            throw posixError("listen failed")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                getsockname(fd, socketPointer, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw posixError("getsockname failed")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func createStaleSocketFile(at path: String) throws {
        close(try boundUnixSocketDescriptor(at: path))
    }

    private func muteListeningSocketDescriptor(at path: String) throws -> Int32 {
        let fd = try boundUnixSocketDescriptor(at: path)
        guard listen(fd, 8) == 0 else {
            let error = posixError("listen failed")
            close(fd)
            throw error
        }
        return fd
    }

    private func boundUnixSocketDescriptor(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket failed")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind failed")
            close(fd)
            throw error
        }
        return fd
    }

    private func posixError(_ message: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"]
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stdinPipe = stdinText.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        if let stdinText, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(stdinText.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
