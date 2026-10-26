import CryptoKit
import Foundation
import SwiftUI

/// CLI fixture linked with the complete real production Document and ExportState.
@main
struct DownloadExportRuntime {
    final class Token: Sendable {}
    @MainActor static var assertions = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        assertions += 1
        if !value { failures += 1; print("FAIL: \(message)") }
    }
    @MainActor static func main() throws {
        let source = Token(), other = Token(), state = MobileLocalDirectFileExportState()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        check(!FileManager.default.fileExists(atPath: root.path), "exclusive fixture root")
        if failures != 0 { exit(1) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for (index, bytes) in [Data(), Data("abc".utf8), Data([0, 255, 254, 192, 128]), Data(repeating: 255, count: 2_097_152)].enumerated() {
            let doc = try MobileLocalDirectFileDownloadDocument(data: bytes)
            let wrapper = try doc.makeFileWrapper()
            check(wrapper.isRegularFile && wrapper.regularFileContents == bytes, "full wrapper bytes")
            let destination = root.appendingPathComponent("vector-\(index)")
            check(!FileManager.default.fileExists(atPath: destination.path), "new file")
            try wrapper.write(to: destination, options: [], originalContentsURL: nil)
            let readback = try Data(contentsOf: destination)
            check(readback == bytes, "full readback")
            let hash = SHA256.hash(data: readback).map { String(format: "%02x", $0) }.joined()
            if index == 0 { check(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "known empty hash") }
            if index == 1 { check(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "known abc hash") }
            check(state.begin(source: source, data: bytes, filename: "file.bin"), "begin bounded bytes")
            check(state.snapshot?.document.data == bytes, "snapshot bytes")
            state.reset()
        }
        do { _ = try MobileLocalDirectFileDownloadDocument(data: Data(repeating: 0, count: 2_097_153)); check(false, "oversize rejected") }
        catch MobileLocalDirectFileDownloadDocument.Failure.tooLarge { check(true, "oversize rejected") }
        check(MobileLocalDirectFileDownloadDocument.readableContentTypes.isEmpty, "export-only")
        check(MobileLocalDirectFileDownloadDocument.writableContentTypes == [.data], "generic data")
        for name in ["", ".", "..", "/a", "a/b", "a\0b", String(repeating: "a", count: 4097), String(repeating: "中", count: 1366)] {
            check(!state.begin(source: source, data: Data(), filename: name), "invalid leaf")
            check(state.snapshot == nil && !state.isPresented && state.status == .failed, "safe rejection")
            state.reset()
        }
        for name in ["file.bin", "é", "e\u{301}", "%2f", String(repeating: "a", count: 4096)] {
            check(state.begin(source: source, data: Data(), filename: name), "valid leaf")
            check(state.snapshot?.filename.utf8.elementsEqual(name.utf8) == true, "leaf unchanged")
            state.reset()
        }
        check(!state.begin(source: source, data: Data(repeating: 0, count: 2_097_153), filename: "f"), "begin oversize rejected")
        check(state.status == .failed && state.snapshot == nil && !state.isPresented, "safe oversize")
        state.reset()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for outcome in [MobileLocalDirectFileExportState.Outcome.saved, .failed, .cancelled] {
            check(state.begin(source: source, data: Data(), filename: "empty"), "begin outcome")
            let id = state.snapshot!.attemptID
            check(!state.begin(source: other, data: Data([1]), filename: "other"), "duplicate begin rejected")
            check(state.snapshot?.attemptID == id && state.isPresented && state.status == nil, "duplicate preserves state")
            state.isPresented = false
            check(state.snapshot?.attemptID == id, "dismissal before callback keeps snapshot")
            check(state.finish(attemptID: id, currentSource: source, outcome: outcome), "current callback")
            check(state.snapshot == nil && !state.isPresented, "finish releases snapshot")
            switch outcome {
            case .saved: check(state.status == .saved, "saved")
            case .failed: check(state.status == .failed, "safe failure")
            case .cancelled: check(state.status == nil, "quiet cancel")
            }
            check(!state.finish(attemptID: id, currentSource: source, outcome: .saved), "duplicate callback ignored")
            state.reset()
        }
        for outcome in [MobileLocalDirectFileExportState.Outcome.saved, .failed, .cancelled] {
            check(state.begin(source: source, data: Data([1]), filename: "old"), "old begin")
            let old = state.snapshot!.attemptID
            state.reset()
            check(state.begin(source: source, data: Data([2]), filename: "new"), "same source new begin")
            let fresh = state.snapshot!.attemptID
            check(old != fresh, "unique attempt")
            check(!state.finish(attemptID: old, currentSource: source, outcome: outcome), "stale attempt returns false")
            check(state.snapshot?.attemptID == fresh && state.snapshot?.document.data == Data([2]), "stale attempt preserves snapshot")
            check(state.status == nil, "stale attempt preserves status")
            check(state.isPresented, "stale attempt preserves presentation")
            state.reset()
        }
        for current in [other as Token?, nil] {
            check(state.begin(source: source, data: Data(), filename: "old"), "stale source begin")
            let id = state.snapshot!.attemptID
            check(!state.finish(attemptID: id, currentSource: current, outcome: .saved), "stale source no success")
            check(state.snapshot == nil && !state.isPresented && state.status == nil, "stale source clears old UI")
        }
        check(state.begin(source: source, data: Data(), filename: "old"), "begin invalidation")
        let old = state.snapshot!.attemptID
        state.invalidateIfSourceChanged(currentSource: source)
        check(state.snapshot?.attemptID == old && state.isPresented, "same owner preserved")
        state.invalidateIfSourceChanged(currentSource: other)
        check(state.snapshot == nil && !state.isPresented && state.status == nil, "new owner resets")
        check(state.begin(source: other, data: Data([9]), filename: "new"), "replacement begins")
        let fresh = state.snapshot!.attemptID
        check(!state.finish(attemptID: old, currentSource: other, outcome: .failed), "old callback ignored")
        check(state.snapshot?.attemptID == fresh && state.status == nil && state.isPresented, "replacement preserved")
        state.invalidateIfSourceChanged(currentSource: nil)
        check(state.snapshot == nil && !state.isPresented && state.status == nil, "nil owner resets")
        var retained: Token? = Token()
        weak var witness = retained
        check(state.begin(source: retained!, data: Data(), filename: "retain"), "begin strong identity")
        retained = nil
        check(witness != nil && state.snapshot?.source === witness, "strong source prevents ABA")
        state.reset()
        check(witness == nil, "reset releases source")
        check(try FileManager.default.contentsOfDirectory(atPath: root.path) == filesBefore, "state never writes files")
        let fm = FileManager.default
        print("Foundation home=\(fm.homeDirectoryForCurrentUser.path) support=\(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path) temp=\(fm.temporaryDirectory.path)")
        print("ASSERTIONS \(assertions) FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
