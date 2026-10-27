"""Persistent source guard, not SwiftUI or real-provider execution."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"


def source(name):
    path = FEATURE / name
    return path.read_text() if path.exists() else ""


class LocalDirectFileUploadUIGuardTests(unittest.TestCase):
    def test_root_owned_picker_and_external_controls(self):
        view = source("MobileLocalDirectFilesView.swift")
        self.assertEqual(view.count("@State"), 3)
        self.assertIn("@State private var importReader = MobileLocalDirectFileImportReader()", view)
        self.assertIn("@State private var importSession: MobileLocalDirectFileImportSession?", view)
        self.assertEqual(view.count("NavigationStack {"), 1)
        self.assertEqual(view.count(".fileImporter("), 1)
        self.assertIn(".safeAreaInset(edge: .bottom)", view)
        self.assertIn("if previewPresentation == nil", view)
        self.assertIn("MobileLocalDirectFileUploadView(", view)
        self.assertIn("if let selection = importSession", view)
        self.assertIn("@Bindable var selection = selection", view)
        self.assertIn("isPresented: $selection.isPickerPresented", view)
        self.assertIn("allowedContentTypes: [.data], allowsMultipleSelection: false", view)
        self.assertIn("onCompletion:", view)
        self.assertIn("onCancellation:", view)
        self.assertEqual(view.count("guard importSession === selection else { return }"), 2)
        self.assertIn("guard urls.count == 1, let url = urls.first", view)
        self.assertIn("selection.select(url: url)", view)
        self.assertIn("selection.pickerFailed()", view)
        self.assertIn("selection.cancel()", view)
        self.assertIn("reader: importReader", view)
        for forbidden in [".sheet(", "onChange(of: selection.isPickerPresented", "onChange(of: importSession?.isPickerPresented",
                          "Data(contentsOf:", "FileManager", "TaskComposerAttachmentStager", "Photos", "localizedDescription"]:
            self.assertNotIn(forbidden, view)

    def test_retirement_and_explicit_actions_only(self):
        view = source("MobileLocalDirectFilesView.swift")
        self.assertIn("guard session.canUploadFiles, !importBusy else { return }", view)
        self.assertIn("if identity != nil { retireImport() }", view)
        self.assertIn(".onChange(of: session.directoryRevision)", view)
        self.assertIn(".onDisappear { retireImport(); session.closeUpload(); session.closePreview() }", view)
        self.assertIn("retireImport(); session.closeUpload(); session.closePreview(); dismiss()", view)
        self.assertIn("importSession?.invalidate(); importSession = nil", view)
        self.assertIn("retireImport(); session.closeUpload(); session.refresh()", view)
        self.assertNotIn(".start()", view)
        upload = source("MobileLocalDirectFileUploadView.swift")
        self.assertTrue(upload)
        self.assertEqual(upload.count("child.start()"), 1)
        self.assertIn('defaultValue: "Upload")) { child.start() }', upload)
        self.assertIn("if let child = session.uploadSession", upload)
        self.assertIn("if child.requiresFolderRefresh", upload)
        self.assertIn("Text(verbatim: child.fileName)", upload)
        self.assertIn("Text(verbatim: child.path)", upload)
        self.assertIn("Text(verbatim: receipt.path)", upload)
        self.assertIn("child.sourceByteCount", upload)
        self.assertIn("child.cancel()", upload)
        self.assertIn("importSession?.cancel()", upload)
        self.assertIn("Done and Refresh", upload)
        for forbidden in [".onDisappear", ".task(", ".onChange", "onAppear", ".sheet(", "NavigationStack",
                          "absolutePath", "shellQuotedPath", "canInsertPath", "sendInput", "sendRequest", "UIPasteboard",
                          "Photos", "TextField", "localizedDescription", "refresh()", "URL(", "FileManager", "Data(contentsOf:"]:
            self.assertNotIn(forbidden, upload)

    def test_safe_messages_and_catalogs(self):
        upload = source("MobileLocalDirectFileUploadView.swift")
        self.assertTrue(upload)
        for case in ["invalidSelection", "unsupported", "unsupportedWorkspace", "permissionDenied", "directoryUnavailable",
                     "directoryChanged", "fileChanged", "alreadyExists", "tooLarge", "integrityMismatch", "invalidResponse",
                     "unavailable", "disconnected", "notDirectory", "invalidName", "notAFile"]:
            self.assertIn(f"case .{case}:", upload)
        self.assertIn("Upload may have completed. Refresh the folder before trying again.", upload)
        self.assertIn("2 MiB", upload)
        self.assertIn("never replaced", upload)
        self.assertIn("Rename the source file", upload)
        keys = dict(re.findall(r'localized: "(direct\.upload\.[^"]+)", defaultValue: "([^"]+)"', upload))
        self.assertGreaterEqual(len(keys), 25)
        catalogs = [json.loads((ROOT / p).read_text())["strings"] for p in
                    ["Resources/Localizable.xcstrings", "ios/cmux/Resources/Localizable.xcstrings"]]
        for key, english in keys.items():
            self.assertIn(key, catalogs[0])
            self.assertIn(key, catalogs[1])
            self.assertEqual(catalogs[0][key], catalogs[1][key])
            rows = catalogs[0][key]["localizations"]
            self.assertEqual(set(rows), {"en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"})
            for locale, entry in rows.items():
                self.assertEqual(entry["stringUnit"]["state"], "translated")
                value = entry["stringUnit"]["value"]
                self.assertTrue(value)
                if locale == "en":
                    self.assertEqual(value, english)
                else:
                    self.assertNotEqual(value, english)
        self.assertNotIn("Uploads are not available yet.", source("MobileLocalDirectFilesView.swift"))
        self.assertIn("File previews and downloads are unavailable for this folder.", source("MobileLocalDirectFilesView.swift"))
        self.assertNotIn("direct.upload.", source("MobileLocalDirectFilesView.swift"))

    def test_explicit_captured_terminal_insertion(self):
        root = source("MobileLocalDirectRootScene.swift")
        files = source("MobileLocalDirectFilesView.swift")
        upload = source("MobileLocalDirectFileUploadView.swift")
        for text in ["let terminal = controller.terminalSession", "terminalTitle: terminalTitle",
                     "canQueuePath: { [session, terminal] child in", "queuePath: { [session, terminal] child in",
                     "controller.canQueueUploadedPath(from: session, upload: child, into: terminal)",
                     "controller.queueUploadedPath(from: session, upload: child, into: terminal)"]:
            self.assertIn(text, root)
        self.assertEqual(root.count("guard let terminal else { return false }"), 2)
        for view in [files, upload]:
            self.assertIn("let terminalTitle: String?", view)
            self.assertIn("let canQueuePath: (MobileLocalDirectFileUploadSession) -> Bool", view)
            self.assertIn("let queuePath: (MobileLocalDirectFileUploadSession) -> Bool", view)
        self.assertIn("queuePath: queuePathAndShowTerminal", files)
        succeeded = upload.split("case .succeeded:", 1)[1].split("case .failed", 1)[0]
        for text in ["Text(verbatim: terminalTitle)", 'localized: "direct.upload.insert"',
                     "if !queuePath(child) { failedInsertion = child }", ".disabled(!canQueuePath(child))",
                     "if failedInsertion === child", 'localized: "direct.upload.insertFailed"',
                     "Queues a quoted path without pressing Return. Check the active program and input first."]:
            self.assertIn(text, succeeded)
        self.assertIn("@State private var failedInsertion: MobileLocalDirectFileUploadSession?", upload)
        self.assertEqual(upload.count("queuePath(child)"), 1)
        for view in [files, upload]:
            for forbidden in ["enqueueLiteralText", "terminal.input", "sendRequest", "shellQuotedPath"]:
                self.assertNotIn(forbidden, view)

    def test_linux_guard_wiring(self):
        workflow = (ROOT / ".github/workflows/test-ios.yml").read_text()
        self.assertIn("      - name: Guard local direct file download UI wiring\n        run: python3 ios/tests/test_local_direct_file_download_ui.py\n\n"
                      "      - name: Guard local direct file upload UI wiring\n        run: python3 ios/tests/test_local_direct_file_upload_ui.py\n", workflow)


if __name__ == "__main__":
    unittest.main()
