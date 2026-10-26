import Foundation
import Observation

/// Owns one explicit export attempt, independently of networking and provider URLs.
@MainActor @Observable
final class MobileLocalDirectFileExportState {
    struct Snapshot: Sendable {
        let attemptID: UUID
        // Strong identity prevents pointer reuse while a provider callback is outstanding.
        let source: any AnyObject & Sendable
        let document: MobileLocalDirectFileDownloadDocument
        let filename: String
    }
    enum Status { case saved, failed }
    enum Outcome { case saved, failed, cancelled }

    private(set) var snapshot: Snapshot?
    var isPresented = false
    private(set) var status: Status?

    @discardableResult
    func begin(source: any AnyObject & Sendable, data: Data, filename: String) -> Bool {
        guard snapshot == nil, !isPresented else { return false }
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.contains("\0"), filename.utf8.count <= 4_096 else { status = .failed; return false }
        do {
            let document = try MobileLocalDirectFileDownloadDocument(data: data)
            status = nil
            snapshot = Snapshot(attemptID: UUID(), source: source, document: document, filename: filename)
            isPresented = true
            return true
        } catch { status = .failed; return false }
    }

    /// Only the captured current attempt may retire its current owner or report a result.
    @discardableResult
    func finish(attemptID: UUID, currentSource: (any AnyObject & Sendable)?, outcome: Outcome) -> Bool {
        guard let snapshot, snapshot.attemptID == attemptID else { return false }
        let matches = snapshot.source === currentSource
        reset()
        guard matches else { return false }
        switch outcome {
        case .saved: status = .saved
        case .failed: status = .failed
        case .cancelled: break
        }
        return true
    }

    func invalidateIfSourceChanged(currentSource: (any AnyObject & Sendable)?) {
        if let snapshot, snapshot.source !== currentSource { reset() }
    }

    func reset() { snapshot = nil; isPresented = false; status = nil }
}
