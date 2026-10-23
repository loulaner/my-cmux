import Foundation
import CmuxIrohTransport

/// In-memory credential storage with deterministic suspension points and failures.
actor LocalAuthorizationCredentialFake: CmxIrohSecureCredentialStoring {
    enum Failure: Error { case read, write, delete }
    var records: [String: Data] = [:]
    var accessibilities: [CmxIrohSecureCredentialAccessibility] = []
    private var failure: Failure?
    private var blockedOperation: Failure?
    private var gate: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func setFailure(_ value: Failure?) { failure = value }
    func corrupt(_ data: Data) { for key in records.keys { records[key] = data } }
    func blockNext(_ operation: Failure) { blockedOperation = operation }
    func waitUntilBlocked() async {
        if gate != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    private func pause(_ operation: Failure) async throws {
        if blockedOperation == operation {
            blockedOperation = nil
            await withCheckedContinuation {
                gate = $0
                observer?.resume()
                observer = nil
            }
        }
        if failure == operation { throw operation }
    }
    func read(account: String) async throws -> Data? {
        let captured = records[account]
        try await pause(.read)
        return captured
    }
    func write(_ data: Data, account: String, accessibility: CmxIrohSecureCredentialAccessibility) async throws {
        try await pause(.write)
        records[account] = data
        accessibilities.append(accessibility)
    }
    func delete(account: String) async throws { try await pause(.delete); records[account] = nil }
    func deleteAll() async throws { records = [:] }
}
