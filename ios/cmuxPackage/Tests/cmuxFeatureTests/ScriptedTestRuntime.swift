import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import Foundation

/// Test-only configuration; requests still pass through the real RPC client/session.
struct ScriptedTestRuntime: MobileSyncRuntime {
    static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let defaultPairingRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
    var supportedRouteKinds: [CmxAttachTransportKind]
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String
    var stackAccessTokenForStatusProvider: @Sendable () async -> String?
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { throw AuthError.unauthorized }
    var rpcRequestTimeoutNanoseconds: UInt64 = defaultRPCRequestTimeoutNanoseconds
    var pairingRequestTimeoutNanoseconds: UInt64 = defaultPairingRequestTimeoutNanoseconds
    var pairingAttemptTimeoutNanoseconds: UInt64 = 30_000_000_000
    var now: @Sendable () -> Date = Date.init
    var supportsServerPushEvents: Bool = false
    // Optional lanes and real deadline sleeps deliberately use protocol defaults.
}
