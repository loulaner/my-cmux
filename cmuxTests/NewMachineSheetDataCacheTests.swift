import AppKit
import CmuxAuthRuntime
import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The account-scoped, on-demand cache used by the New Machine sheet.
@MainActor
@Suite("New Machine sheet data cache")
struct NewMachineSheetDataCacheTests {
    /// Mutable test state the fetch closures share on the main actor.
    @MainActor
    final class Backend {
        var scope: AuthenticatedTeamScope?
        var planId = "pro"
        var pageFetches = 0
        var holdsPage = false
        var isHoldingPage = false
        let pageStarted = Gate()
        let pageFinished = Gate()
        let release = AsyncStream<Void>.makeStream()
    }

    private static func scope(_ account: String) -> AuthenticatedTeamScope {
        AuthenticatedTeamScope(
            session: AuthenticatedSessionIdentity(generation: 1, accountID: account),
            teamID: "team-\(account)",
            generation: 1
        )
    }

    private static let catalog = CloudNetworkPresetCatalog(
        presets: [CloudNetworkPreset(id: "npm", label: "npm", domains: ["registry.npmjs.org"])],
        requiredDomains: ["files.cmux.com"]
    )

    private static func makeCache(_ backend: Backend) -> NewMachineSheetDataCache {
        NewMachineSheetDataCache(
            currentScope: { backend.scope },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                backend.pageFetches += 1
                let planId = backend.planId
                if backend.holdsPage {
                    backend.isHoldingPage = true
                    backend.pageStarted.signal()
                    for await _ in backend.release.stream { break }
                    backend.pageFinished.signal()
                }
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: planId, freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192, 32768],
                    lockedMemoryOptionsMb: [32768], memoryUpgradePlanId: "max"
                ))
            },
            fetchCatalog: { Self.catalog }
        )
    }

    @Test func warmCacheAnswersWithoutWaitingOnAnotherFetch() async {
        let backend = Backend()
        backend.scope = Self.scope("a")
        let cache = Self.makeCache(backend)

        let warmed = await cache.data()
        #expect(warmed?.limits?.memoryOptionsMb == [4096, 8192, 32768])
        #expect(backend.pageFetches == 1)

        // Presenting reads the ready data synchronously; the fetch count
        // proves the sheet did not wait on the network for it.
        let ready = cache.readyData
        #expect(ready?.limits?.lockedMemoryOptionsMb == [32768])
        #expect(ready?.plan?.planId == "pro")
        #expect(backend.pageFetches == 1)
    }

    @Test func switchingAccountsDropsTheOldAccountsPlan() async {
        let backend = Backend()
        backend.scope = Self.scope("a")
        let cache = Self.makeCache(backend)
        _ = await cache.data()
        #expect(cache.readyData != nil)

        backend.scope = Self.scope("b")
        #expect(cache.readyData == nil)
        #expect(cache.currentData == nil)

        backend.scope = nil
        #expect(cache.currentData == nil)
        #expect(!cache.refresh())
    }

    @Test func aLateAnswerForAReplacedAccountIsNeverInstalled() async throws {
        let backend = Backend()
        backend.scope = Self.scope("a")
        backend.planId = "max"
        backend.holdsPage = true
        let cache = Self.makeCache(backend)

        #expect(cache.refresh())
        try await backend.pageStarted.wait()

        // Account B signs in while A's list request is still in flight.
        backend.scope = Self.scope("b")
        backend.planId = "pro"
        backend.holdsPage = false
        let bData = await cache.data()
        backend.release.continuation.yield(())
        try await backend.pageFinished.wait()

        #expect(bData?.plan?.planId == "pro")
        #expect(cache.readyData?.plan?.planId == "pro")
    }
    @Test func sizesAreReadyWhileNetworkPresetsAreStillLoading() async {
        let releaseCatalog = AsyncStream<Void>.makeStream()
        defer { releaseCatalog.continuation.finish() }
        let account = Self.scope("first-open")
        var pageFetches = 0
        let cache = NewMachineSheetDataCache(
            currentScope: { account },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                pageFetches += 1
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192]
                ))
            },
            fetchCatalog: {
                for await _ in releaseCatalog.stream { break }
                return Self.catalog
            }
        )
        let data = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(data?.limits?.memoryOptionsMb == [4096, 8192])
        #expect(cache.readyData != nil)
        #expect(data?.catalog == nil)
        _ = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(pageFetches == 1)
    }

    @Test func machineListWithoutLimitsIsNotAReadyPlan() async {
        let account = Self.scope("missing-plan")
        let cache = NewMachineSheetDataCache(
            currentScope: { account },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: { VMListPage(vms: []) },
            fetchCatalog: { Self.catalog }
        )
        _ = await cache.data()
        #expect(cache.readyData == nil)
        #expect(cache.currentData?.hasPlan == false)
    }

    @Test func activeListenerRefreshesWhenCloudIsEnabled() async throws {
        let backend = Backend()
        backend.scope = Self.scope("enable")
        let center = NotificationCenter()
        var enabled = false
        let delivered = Gate()
        let cache = NewMachineSheetDataCache(
            currentScope: { backend.scope },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                backend.pageFetches += 1
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192]
                ))
            },
            fetchCatalog: { Self.catalog },
            notificationCenter: center,
            isCloudEnabled: { enabled }
        )
        let listener = cache.addListener { data in
            if data.hasPlan { delivered.signal() }
        }
        defer {
            cache.removeListener(listener)
            delivered.finish()
        }
        cache.start()
        #expect(backend.pageFetches == 0)
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        try await delivered.wait()
        #expect(cache.readyData?.limits?.memoryOptionsMb == [4096, 8192])
        let firstOpen = await cache.data()
        #expect(firstOpen?.hasPlan == true)
        #expect(backend.pageFetches == 1)
        enabled = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(cache.readyData == nil)
    }

    @Test func failedPlanCanRetryWhileCatalogIsPending() async {
        let releaseCatalog = AsyncStream<Void>.makeStream()
        defer { releaseCatalog.continuation.finish() }
        let account = Self.scope("retry-plan")
        var attempts = 0
        let cache = NewMachineSheetDataCache(
            currentScope: { account },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192]
                ))
            },
            fetchCatalog: {
                for await _ in releaseCatalog.stream { break }
                return Self.catalog
            }
        )
        let first = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(first?.hasPlan != true)
        let second = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(second?.limits?.memoryOptionsMb == [4096, 8192])
        #expect(attempts == 2)
    }

    /// Buffered events with a real timeout: no sleeps to guess scheduling and
    /// no unbounded yield loops. Timeout cancels the suspended stream iterator.
    @MainActor
    final class Gate {
        private let events = AsyncStream<Void>.makeStream()
        func signal() { events.continuation.yield(()) }
        func finish() { events.continuation.finish() }
        func wait() async throws {
            let stream = events.stream
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    return await iterator.next() != nil
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    return false
                }
                defer { group.cancelAll() }
                let received = try await group.next()
                try #require(received == true, "Timed out waiting for a controlled cache event")
            }
        }
    }

    /// The next pull acknowledges that the cache finished processing the
    /// previous scope event, including its synchronous refresh decision.
    @MainActor
    final class ScopeFeed {
        private let events = AsyncStream<AuthenticatedTeamScope?>.makeStream()
        private var iterator: AsyncStream<AuthenticatedTeamScope?>.Iterator
        let pulled = Gate()
        init() { iterator = events.stream.makeAsyncIterator() }
        func stream() -> AsyncStream<AuthenticatedTeamScope?> {
            AsyncStream(unfolding: { await self.next() })
        }
        private func next() async -> AuthenticatedTeamScope?? {
            pulled.signal()
            var iterator = self.iterator
            let result = await iterator.next()
            self.iterator = iterator
            return result
        }
        func send(_ scope: AuthenticatedTeamScope?) async throws {
            events.continuation.yield(scope)
            try await pulled.wait()
        }
        func finish() { events.continuation.finish() }
    }

    @MainActor
    final class DemandBackend {
        var scope: AuthenticatedTeamScope? = NewMachineSheetDataCacheTests.scope("a")
        var enabled = true
        var pages = 0
        var catalogs = 0
        let feed = ScopeFeed()
        let center = NotificationCenter()
        let delivered = Gate()
        let pageStarted = Gate()
        let releasePage = Gate()
        var holdPage = false

        func makeCache() -> NewMachineSheetDataCache {
            NewMachineSheetDataCache(
                currentScope: { self.scope },
                scopes: { self.feed.stream() },
                fetchPage: {
                    self.pages += 1
                    let plan = self.scope?.teamID ?? "none"
                    self.pageStarted.signal()
                    if self.holdPage { try await self.releasePage.wait() }
                    return VMListPage(vms: [], limits: VMPlanLimits(
                        planId: plan, freeAccessWindowDays: 0, memoryOptionsMb: [4096]
                    ))
                },
                fetchCatalog: {
                    self.catalogs += 1
                    return NewMachineSheetDataCacheTests.catalog
                },
                notificationCenter: center,
                isCloudEnabled: { self.enabled }
            )
        }
        func start(_ cache: NewMachineSheetDataCache) async throws {
            cache.start()
            try await feed.pulled.wait()
            try await feed.send(scope)
        }
        func move(to scope: AuthenticatedTeamScope?) async throws {
            self.scope = scope
            try await feed.send(scope)
        }
        func enable(_ value: Bool) {
            enabled = value
            center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        }
        func observe(_ cache: NewMachineSheetDataCache) -> UUID {
            cache.addListener { data in
                if data.hasPlan, data.catalog != nil { self.delivered.signal() }
            }
        }
    }

    @Test func idleStartupScopeFeatureAndActivationDoNotFetch() async throws {
        let backend = DemandBackend()
        let cache = backend.makeCache()
        defer { backend.feed.finish() }
        try await backend.start(cache)
        #expect(backend.pages == 0 && backend.catalogs == 0)
        try await backend.move(to: Self.scope("b"))
        #expect(backend.pages == 0 && backend.catalogs == 0)
        let team = AuthenticatedTeamScope(session: Self.scope("b").session, teamID: "other-team", generation: 2)
        try await backend.move(to: team)
        #expect(cache.currentData == nil)
        backend.enable(false)
        backend.enable(true)
        backend.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(backend.pages == 0 && backend.catalogs == 0)
        // The acknowledged next stream pull also covers same-scope delivery.
        try await backend.feed.send(team)
        #expect(backend.pages == 0 && backend.catalogs == 0)
        #expect(cache.currentData == nil)
    }

    @Test func explicitReadsFetchBothEndpointsAndReuseOnlyCurrentScope() async throws {
        let backend = DemandBackend()
        let cache = backend.makeCache()
        defer { backend.feed.finish() }
        try await backend.start(cache)
        let listener = backend.observe(cache)
        #expect(backend.pages == 0 && backend.catalogs == 0) // addListener is not demand by itself
        let first = await cache.data(waitingAtMost: .seconds(1))
        try await backend.delivered.wait()
        #expect(first?.limits?.planId == "team-a")
        #expect(backend.pages == 1 && backend.catalogs == 1)
        _ = await cache.data(waitingAtMost: .seconds(1))
        #expect(backend.pages == 1 && backend.catalogs == 1)
        cache.removeListener(listener)
        try await backend.move(to: Self.scope("b"))
        #expect(cache.readyData == nil && cache.currentData == nil)
        #expect(backend.pages == 1 && backend.catalogs == 1)
        backend.enable(false)
        backend.enable(true)
        try await backend.feed.send(backend.scope)
        #expect(backend.pages == 1 && backend.catalogs == 1)
        let secondListener = backend.observe(cache)
        defer { cache.removeListener(secondListener) }
        let second = await cache.data(waitingAtMost: .seconds(1))
        try await backend.delivered.wait()
        #expect(second?.limits?.planId == "team-b")
        #expect(backend.pages == 2 && backend.catalogs == 2)
    }

    @Test func activeListenerRefreshesForScopeAndFeatureButNotActivation() async throws {
        let backend = DemandBackend()
        let cache = backend.makeCache()
        defer { backend.feed.finish() }
        try await backend.start(cache)
        let listener = backend.observe(cache)
        defer { cache.removeListener(listener) }
        try await backend.move(to: Self.scope("b"))
        try await backend.delivered.wait()
        #expect(cache.readyData?.limits?.planId == "team-b")
        #expect(backend.pages == 1 && backend.catalogs == 1)
        let team = AuthenticatedTeamScope(session: Self.scope("b").session, teamID: "second-team", generation: 2)
        try await backend.move(to: team)
        try await backend.delivered.wait()
        #expect(cache.readyData?.limits?.planId == "second-team")
        #expect(backend.pages == 2 && backend.catalogs == 2)
        backend.enable(false)
        #expect(cache.currentData == nil)
        backend.scope = Self.scope("c")
        backend.enable(true)
        try await backend.delivered.wait()
        #expect(cache.readyData?.limits?.planId == "team-c")
        #expect(backend.pages == 3 && backend.catalogs == 3)
        backend.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await backend.move(to: nil)
        #expect(cache.currentData == nil)
        #expect(!cache.refresh())
        #expect(backend.pages == 3 && backend.catalogs == 3)
    }

    @Test func disabledOrSignedOutExplicitReadsNeverFetch() async throws {
        let backend = DemandBackend()
        backend.scope = nil
        let cache = backend.makeCache()
        defer { backend.feed.finish() }
        try await backend.start(cache)
        #expect(await cache.data(waitingAtMost: .seconds(1)) == nil)
        backend.enable(false)
        try await backend.move(to: Self.scope("a"))
        let listener = backend.observe(cache)
        defer { cache.removeListener(listener) }
        try await backend.feed.send(backend.scope)
        #expect(await cache.data(waitingAtMost: .seconds(1)) == nil)
        #expect(!cache.refresh())
        #expect(backend.pages == 0 && backend.catalogs == 0)
    }

    @Test func deadlineAndCancellationReleaseWaitersWithoutOwningTheFetch() async throws {
        let backend = DemandBackend()
        backend.holdPage = true
        let cache = backend.makeCache()
        defer { backend.feed.finish(); backend.releasePage.finish() }
        let timed = await cache.data(waitingAtMost: .milliseconds(20))
        #expect(timed?.hasPlan != true)
        try await backend.pageStarted.wait()
        let entered = Gate()
        let waiting = Task { @MainActor in
            entered.signal()
            return await cache.data(waitingAtMost: .seconds(1))
        }
        try await entered.wait()
        waiting.cancel()
        #expect(await waiting.value == nil)
        let listener = backend.observe(cache)
        defer { cache.removeListener(listener) }
        backend.releasePage.signal()
        try await backend.delivered.wait()
        #expect(cache.readyData?.limits?.planId == "team-a")
        // Joining the pending page may revalidate an already completed catalog.
        #expect(backend.pages == 1 && backend.catalogs == 2)
    }

    @Test func ingestReusesFreshDataWithoutStartingEitherRequest() async throws {
        let backend = DemandBackend()
        let cache = backend.makeCache()
        defer { backend.feed.finish() }
        try await backend.start(cache)
        cache.ingest(page: VMListPage(vms: [], limits: VMPlanLimits(
            planId: "ingested", freeAccessWindowDays: 0, memoryOptionsMb: [8192]
        )), scope: backend.scope)
        #expect(await cache.data(waitingAtMost: .seconds(1))?.limits?.planId == "ingested")
        #expect(backend.pages == 0 && backend.catalogs == 0)
        try await backend.move(to: Self.scope("b"))
        cache.ingest(page: VMListPage(vms: [], limits: VMPlanLimits(
            planId: "old", freeAccessWindowDays: 0
        )), scope: Self.scope("a"))
        #expect(cache.currentData == nil)
        #expect(backend.pages == 0 && backend.catalogs == 0)
    }

    @Test func cancelledLatePageAndCatalogCannotOverwriteNewScope() async throws {
        let backend = DemandBackend()
        let pageStarted = Gate()
        let catalogStarted = Gate()
        let pageFinished = Gate()
        let catalogFinished = Gate()
        // These deliberately ignore cancellation until released, like a
        // transport returning a response after its request was cancelled.
        var releasePage: CheckedContinuation<Void, Never>?
        var releaseCatalog: CheckedContinuation<Void, Never>?
        let cache = NewMachineSheetDataCache(
            currentScope: { backend.scope },
            scopes: { backend.feed.stream() },
            fetchPage: {
                backend.pages += 1
                let team = backend.scope?.teamID ?? "none"
                if team == "team-a" {
                    pageStarted.signal()
                    await withCheckedContinuation { releasePage = $0 }
                    pageFinished.signal()
                }
                return VMListPage(vms: [], limits: VMPlanLimits(planId: team, freeAccessWindowDays: 0))
            },
            fetchCatalog: {
                backend.catalogs += 1
                let team = backend.scope?.teamID ?? "none"
                if team == "team-a" {
                    catalogStarted.signal()
                    await withCheckedContinuation { releaseCatalog = $0 }
                    catalogFinished.signal()
                }
                return CloudNetworkPresetCatalog(presets: [], requiredDomains: [team])
            }
        )
        defer {
            backend.feed.finish()
            releasePage?.resume()
            releaseCatalog?.resume()
        }
        try await backend.start(cache)
        #expect(cache.refresh())
        try await pageStarted.wait()
        try await catalogStarted.wait()
        let listener = backend.observe(cache)
        defer { cache.removeListener(listener) }
        try await backend.move(to: Self.scope("b"))
        try await backend.delivered.wait()
        #expect(cache.readyData?.limits?.planId == "team-b")
        #expect(cache.currentData?.catalog?.requiredDomains == ["team-b"])
        releasePage?.resume(); releasePage = nil
        releaseCatalog?.resume(); releaseCatalog = nil
        try await pageFinished.wait()
        try await catalogFinished.wait()
        #expect(cache.readyData?.limits?.planId == "team-b")
        #expect(cache.currentData?.catalog?.requiredDomains == ["team-b"])
        #expect(backend.pages == 2 && backend.catalogs == 2)
    }

}
