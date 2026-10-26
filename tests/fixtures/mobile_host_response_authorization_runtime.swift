import Foundation
import Darwin

/*__RPC__*/

// In-memory scheduling seam. No sleeps, transport, real credentials or disk secrets.
@MainActor
private final class Gate {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        arrivals.forEach { $0.resume() }; arrivals = []
        if !released { await withCheckedContinuation { release = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { arrivals.append($0) } }
    }
    func open() { released = true; release?.resume(); release = nil }
}

@MainActor
private enum MobileHostRequestActivity {
    static var begins = 0
    static var ends = 0
    static func beginRequest() { begins += 1 }
    static func endRequest() { ends += 1 }
}

// Complete production method below; dependencies are explicit control-flow spies.
@MainActor
private final class Connection {
    /*__TYPES__*/
    var isClosed = false
    var allowed = true
    var checks = 0
    var handlers = 0
    var authorizedRequests = 0
    var pauseSecond = false
    var policyDenial = false
    var subscription = false
    let handlerGate = Gate()
    let authGate = Gate()
    let result: MobileHostRPCResult
    static var readinessCalls = 0
    init(failure: Bool = false) {
        result = failure ? .failure(MobileHostRPCError(code: "synthetic_failure", message: Harness.secret, data: ["detail": Harness.secret]))
            : .ok(["workspaces": [Harness.secret]])
    }
    func isAuthorizationCurrent() async -> Bool {
        checks += 1
        if checks == 2 && pauseSecond { await authGate.pause() }
        return allowed
    }
    func authorizeRequest(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        policyDenial ? .failure(MobileHostRPCError(code: "policy_denied", message: "synthetic policy")) : nil
    }
    func onAuthorizedRequest(_ request: MobileHostRPCRequest) async { authorizedRequests += 1 }
    func handleSubscriptionRPC(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        subscription ? .ok(["stream": "synthetic"]) : nil
    }
    func handleRequest(_ request: MobileHostRPCRequest) async -> MobileHostRPCResult {
        handlers += 1
        await handlerGate.pause()
        return result
    }
    private static func readinessContribution(for request: MobileHostRPCRequest, result: MobileHostRPCResult) -> UsableSessionReadinessContribution? {
        readinessCalls += 1
        guard case let .ok(value) = result, let object = value as? [String: Any],
              let workspaces = object["workspaces"] as? [Any] else { return nil }
        return .workspaceList(count: workspaces.count)
    }
    /*__INTERACTIVE__*/
    /*__METHOD__*/
    /*__HELPER__*/
    func exercise() async -> (Data, Int?)? {
        let request = MobileHostRPCRequest(id: "synthetic-request", method: "workspace.list", params: [:], auth: nil)
        guard let response = await successResponsePayload(for: request) else { return nil }
        var count: Int?
        if case let .workspaceList(value) = response.readinessContribution { count = value }
        return (response.data, count)
    }
}

@MainActor
@main
private struct Harness {
    static let secret = "SYNTHETIC_RESPONSE_SECRET_NOT_A_CREDENTIAL"
    static let focusedOnly = false // __FOCUSED__
    static var assertions = 0
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        if !condition { failures += 1; print("FAIL \(message)") }
    }
    static func decoded(_ data: Data?) -> [String: Any] {
        guard let data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    static func expired(_ response: (Data, Int?)?, _ label: String) {
        let object = decoded(response?.0)
        let error = object["error"] as? [String: Any]
        check(object["id"] as? String == "synthetic-request", "\(label) id")
        check(object["ok"] as? Bool == false, "\(label) failure envelope")
        check(error?["code"] as? String == "admission_expired", "\(label) expired code")
        check(error?["message"] as? String == "The remote device authorization has expired. Reconnect to continue.", "\(label) original message")
        check(object["result"] == nil && error?["data"] == nil, "\(label) no original result/details")
        check(!String(decoding: response?.0 ?? Data(), as: UTF8.self).contains(secret), "\(label) leaked \(secret)")
        check(response?.1 == nil, "\(label) no readiness")
    }
    static func reset() {
        Connection.readinessCalls = 0
        MobileHostRequestActivity.begins = 0; MobileHostRequestActivity.ends = 0
    }
    static func balanced(_ expected: Int) {
        check(MobileHostRequestActivity.begins == expected, "activity begins")
        check(MobileHostRequestActivity.ends == expected, "activity ends")
    }
    static func revoked(failure: Bool) async {
        reset()
        let connection = Connection(failure: failure)
        let task = Task { await connection.exercise() }
        await connection.handlerGate.waitForEntry()
        connection.allowed = false
        connection.handlerGate.open()
        expired(await task.value, failure ? "revoked-failure" : "revoked-success")
        check(connection.handlers == 1 && connection.checks == 2, "handler once / auth twice")
        check(Connection.readinessCalls == 0, "discarded result never reaches readiness")
        balanced(1)
    }
    static func main() async {
        await revoked(failure: false)
        // Fail the baseline before waiting for a second check it never performs.
        if failures > 0 { finish() }
        if !focusedOnly {
            await revoked(failure: true)
            reset()
            let entry = Connection(); entry.allowed = false
            expired(await entry.exercise(), "entry-denied")
            check(entry.handlers == 0 && entry.checks == 1 && entry.authorizedRequests == 0, "entry denial stops work")
            check(Connection.readinessCalls == 0, "entry no readiness"); balanced(0)
            for failure in [false, true] {
                reset()
                let connection = Connection(failure: failure)
                connection.handlerGate.open()
                let response = await connection.exercise()
                let actual = decoded(response?.0)
                let expected = decoded(MobileHostRPCEnvelope.encodeResponse(id: "synthetic-request", result: connection.result))
                check(NSDictionary(dictionary: actual).isEqual(to: expected), "authorized original envelope preserved")
                check(response?.1 == (failure ? nil : 1), "original readiness value")
                check(connection.checks == 2 && connection.handlers == 1, "authorized counts")
                check(Connection.readinessCalls == 1, "authorized readiness called once"); balanced(1)
            }
            // Boundaries use continuations; the baseline-only RED never waits for check two.
            for duringAuth in [false, true] {
                for cancel in [false, true] {
                    for allowed in [false, true] {
                        reset()
                        let connection = Connection(); connection.pauseSecond = duringAuth
                        let task = Task { await connection.exercise() }
                        await connection.handlerGate.waitForEntry()
                        if duringAuth {
                            connection.handlerGate.open()
                            await connection.authGate.waitForEntry()
                        }
                        connection.allowed = allowed
                        if cancel { task.cancel() } else { connection.isClosed = true }
                        if duringAuth { connection.authGate.open() } else { connection.handlerGate.open() }
                        check(await task.value == nil, "closed/cancelled produces no response (auth=\(duringAuth), cancel=\(cancel), allowed=\(allowed))")
                        check(connection.checks == (duringAuth ? 2 : 1) && connection.handlers == 1, "boundary call counts")
                        check(Connection.readinessCalls == 0, "boundary no readiness"); balanced(1)
                    }
                }
            }
            for subscription in [false, true] {
                reset()
                let connection = Connection(); connection.subscription = subscription; connection.policyDenial = !subscription
                let response = await connection.exercise()
                check(response != nil && connection.handlers == 0 && connection.checks == 1, "existing interception paths unchanged")
                check(Connection.readinessCalls == (subscription ? 1 : 0), "interception readiness path"); balanced(1)
            }
        }
        finish()
    }
    static func finish() -> Never {
        print("\(failures == 0 ? "PASS" : "FAIL") response authorization: \(assertions) assertions, \(failures) failures; controlled dependencies, no authentication/network proof")
        exit(failures == 0 ? 0 : 1)
    }
}
