import CmuxCloud
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostIdentityConcurrencyTests {
    @Test(.timeLimit(.minutes(1)))
    func backgroundDefaultsNotificationDoesNotWaitForTheMainThread() async {
        let center = NotificationCenter()
        let environment = AppearanceSettingsUserDefaultsObserver.Environment.live(notificationCenter: center)
        let (deliveries, continuation) = AsyncStream<Void>.makeStream()
        let observer = environment.addDefaultsObserver {
            MainActor.preconditionIsolated()
            continuation.yield()
        }
        defer {
            environment.removeObserver(observer)
            continuation.finish()
        }
        let postReturned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            postReturned.signal()
        }

        // Deliberately hold main while a background preference writer posts.
        // A finite wait reproduces the cache-initialization deadlock without
        // leaving the test host blocked when the assertion fails.
        #expect(Self.waitForPostWhileMainThreadIsOccupied(postReturned))
        var iterator = deliveries.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    private static func waitForPostWhileMainThreadIsOccupied(_ posted: DispatchSemaphore) -> Bool {
        posted.wait(timeout: .now() + 1) == .success
    }

    @Test func prewarmPublishesOneProcessStableSnapshotForConcurrentCallers() async {
        await MobileHostIdentity.prewarm()
        let expected = MobileHostIdentity.deviceIDIfReady()
        #expect(expected != nil)

        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    MobileHostIdentity.deviceID()
                }
            }
            var values: [String] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(values.count == 16)
        #expect(values.allSatisfy { $0 == expected })
        #expect(MobileHostIdentity.deviceIDIfReady() == expected)
    }
}
