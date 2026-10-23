import Darwin
import CmuxControlSocket
import Foundation
import Testing
@testable import CmuxComputerUse

@MainActor
struct ComputerUseUnavailableBuildTests {
    @Test func productionNeverAdoptsHelpers() {
        let policy = ComputerUseHelperTrust()
        #expect(!policy.isAvailableInThisBuild)
        #expect(policy.installSource(nested: URL(fileURLWithPath: "/nonexistent/old.app")) == nil)
        #expect(!policy.isTrusted(URL(fileURLWithPath: "/nonexistent/old.app")))
        let instrumented = ComputerUseHelperTrust(
            isAvailableInThisBuild: false,
            isSigned: { _ in Issue.record("signature callback must not run"); return true },
            installedCandidates: { Issue.record("enumeration must not run"); return [] }
        )
        #expect(instrumented.installSource(nested: URL(fileURLWithPath: "/nested.app")) == nil)
        #expect(!instrumented.isTrusted(URL(fileURLWithPath: "/installed.app")))
    }

    @Test func publicPermissionProbeNeverConnectsToAnExistingSocket() async throws {
        let root = URL(fileURLWithPath: "/tmp/mycmux-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fake.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        url.path.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 104) {
                    _ = strncpy($0, path, 103)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0 && listen(fd, 1) == 0)
        try #require(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
        let paths = ComputerUseRuntimePaths(homeDirectoryURL: root, socketRootDirectoryURL: root,
            environment: [:], bundleIdentifier: "fixture", authenticationToken: "fixture",
            hostAuthenticationToken: "fixture-host")
        #expect(await ComputerUseRuntimeService.queryPermissionStatus(
            paths: paths, transport: SocketTransport(), socketURL: url
        ) == nil)
        let connection = accept(fd, nil, nil)
        let error = errno
        if connection >= 0 { close(connection) }
        #expect(connection == -1 && error == EAGAIN)
    }

    @Test func runtimeIsInertEvenWithSavedPermissionCompletion() async throws {
        let fixture = try HelperRuntimeFixture()
        defer { fixture.files.remove() }
        let defaults = try #require(UserDefaults(suiteName: "mycmux-unavailable-\(UUID().uuidString)"))
        let runtime = ComputerUseRuntimeService(bundle: fixture.bundle, paths: fixture.paths,
                                               userDefaults: defaults, isDisabledByPolicy: { false })
        let old = fixture.paths.installedHelperAppURL
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let sentinel = old.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        #expect(runtime.helperUnavailableInThisBuild)
        runtime.setInitialOnboardingCompletion(true)
        runtime.onboardingWasPresented()
        runtime.onboardingWasCompleted()
        await runtime.setEnabled(true)
        #expect(await runtime.ensureStandaloneHelperInstalled() == nil)
        await runtime.startIfNeededWithinLifecycle()
        #expect(!runtime.prepareRuntimeForLaunch())
        #expect(!runtime.requestAutomaticOnboarding())
        #expect(!runtime.onboardingIsComplete)
        #expect(!runtime.desiredEnabled)
        #expect(!(await runtime.refreshHelperStatus()).accessibility)
        #expect(!(await runtime.refreshHelperStatusAfterPermissionChange()).screenRecording)
        #expect(!((await runtime.openAccessibilitySettings())))
        #expect(!((await runtime.openScreenRecordingSettings())))
        #expect(!(await runtime.stopDaemon()))
        #expect(!(await runtime.publishExternalPermissionReadiness(for: .native, readyOverride: true)))
        await runtime.reapOrphanedHelperStaging()
        for await _ in runtime.permissionStatusEvents() { Issue.record("No TCC observation") }
        #expect(!ComputerUseRuntimeService.registerHelperBundle(at: old, register: { _ in
            Issue.record("No LaunchServices registration"); return 0
        }))
        runtime.stopForTermination()
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.runtimeDirectoryURL.path))
        #expect(runtime.helperAppURL == nil)
    }
}
