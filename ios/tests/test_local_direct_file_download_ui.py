"""Source wiring/localization guards; runtime exporter state has a separate real Swift fixture."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"


def source(name):
    path = FEATURE / name
    return path.read_text() if path.exists() else ""


class LocalDirectFileDownloadUIGuardTests(unittest.TestCase):
    def test_download_section_precedes_preview_and_uses_explicit_actions(self):
        preview = source("MobileLocalDirectFilePreviewView.swift")
        view = source("MobileLocalDirectFileDownloadView.swift")
        self.assertIn("MobileLocalDirectFileDownloadView(session: session)", preview)
        self.assertLess(preview.index("MobileLocalDirectFileDownloadView"), preview.index("switch session.state"))
        self.assertIn(".id(ObjectIdentifier(session))", preview)
        self.assertEqual(source("MobileLocalDirectFilesView.swift").count("session.canOpenFiles"), 2)
        self.assertIn("@State private var exportState = MobileLocalDirectFileExportState()", view)
        self.assertEqual(view.count("session.startDownload()"), 1)
        self.assertIn("Button(String(localized: \"direct.download.start\"", view)
        self.assertIn(".disabled(!session.canDownload || exportBusy)", view)
        self.assertIn("Button(String(localized: \"direct.download.save\"", view)
        self.assertIn("guard !exportBusy, session.canDownload", view)
        self.assertIn("child.state == .ready", view)
        self.assertIn("let data = child.data, data.count == child.byteCount, child.sha256 != nil", view)
        self.assertIn("filename: child.filename", view)
        for forbidden in [".task(", "onAppear", "ShareLink", "QuickLook", "WebView", "URL(", "FileManager", "temporaryDirectory",
                          "localizedDescription", "sendRequest", "disconnect(", "SHA256", "base64", "NavigationStack", ".sheet("]:
            self.assertNotIn(forbidden, view)

    def test_frozen_export_callback_and_owner_retirement(self):
        view = source("MobileLocalDirectFileDownloadView.swift")
        for snippet in ["if let snapshot = exportState.snapshot", "document: snapshot.document", "contentTypes: [.data]",
                        "defaultFilename: snapshot.filename", "onCancellation:", "complete(snapshot, outcome:",
                        "attemptID: snapshot.attemptID", "currentSource: session.downloadSession",
                        "session.downloadSession === snapshot.source", "exportState.snapshot != nil || exportState.isPresented",
                        ".onChange(of: session.downloadSession.map { ObjectIdentifier($0) })",
                        "exportState.invalidateIfSourceChanged(currentSource: session.downloadSession)",
                        ".onDisappear { exportState.reset(); session.closeDownload() }"]:
            self.assertIn(snippet, view)
        self.assertNotIn("onChange(of: exportState.isPresented", view)
        self.assertNotIn("onChange(of: session.canDownload", view)
        self.assertNotIn("onChange(of: session.downloadSession?.state", view)
        self.assertIn("case .directoryChanged:", view)
        self.assertIn("case .disconnected:", view)
        self.assertIn("if session.canDownload && !exportBusy", view)

    def test_document_is_export_only_full_bytes(self):
        doc = source("MobileLocalDirectFileDownloadDocument.swift")
        for snippet in ["FileDocument, Sendable", "let data: Data", "data.count <= 2_097_152", "readableContentTypes: [UTType] { [] }",
                        "writableContentTypes: [UTType] { [.data] }", "throw Failure.unsupportedRead",
                        "try makeFileWrapper()", "FileWrapper(regularFileWithContents: data)"]:
            self.assertIn(snippet, doc)
        for forbidden in ["contents", "prefix(", "SHA256", "FileManager", "URL(", "write(to:", "sendRequest"]:
            self.assertNotIn(forbidden, doc)
        state = source("MobileLocalDirectFileExportState.swift")
        self.assertIn("any AnyObject & Sendable", state)
        self.assertIn("snapshot.attemptID == attemptID", state)
        self.assertIn("snapshot.source === currentSource", state)
        self.assertNotIn("CmuxMobileShell", state)

    def test_catalogs_and_all_safe_failures(self):
        view = source("MobileLocalDirectFileDownloadView.swift")
        pairs = re.findall(r'localized: "(direct\.download\.[^"]+)", defaultValue: "([^"]+)"', view)
        keys = dict(pairs)
        self.assertGreaterEqual(len(keys), 20)
        self.assertEqual(len(keys), len(pairs))
        for name in ["invalidSelection", "unsupported", "unsupportedWorkspace", "permissionDenied", "fileUnavailable", "directoryChanged",
                     "fileChanged", "notAFile", "tooLarge", "invalidResponse", "unavailable", "disconnected"]:
            self.assertIn(f"case .{name}:", view)
            self.assertIn("direct.download.error." + name, keys)
        catalogs = [json.loads((ROOT / p).read_text())["strings"] for p in
                    ["ios/cmux/Resources/Localizable.xcstrings", "Resources/Localizable.xcstrings"]]
        for catalog in catalogs:
            self.assertEqual({k for k in catalog if k.startswith("direct.download.")}, set(keys))
        keys.update({"direct.preview.availability": "Open a file to preview it or download it when supported by this Mac. Uploads are not available yet.",
                     "direct.preview.openHint": "Open File"})
        for key, english in keys.items():
            self.assertEqual(catalogs[0][key], catalogs[1][key])
            locales = catalogs[0][key]["localizations"]
            self.assertEqual(set(locales), {"en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"})
            for locale, entry in locales.items():
                self.assertEqual(entry["stringUnit"]["state"], "translated")
                value = entry["stringUnit"]["value"]
                self.assertTrue(value)
                if locale == "en":
                    self.assertEqual(value, english)
                else:
                    self.assertNotEqual(value, english)

    def test_workflow_and_real_runtime_fixture(self):
        workflow = (ROOT / ".github/workflows/test-ios.yml").read_text()
        self.assertIn("      - name: Guard local direct file preview UI wiring\n        run: python3 ios/tests/test_local_direct_file_preview_ui.py\n\n"
                      "      - name: Guard local direct file download UI wiring\n        run: python3 ios/tests/test_local_direct_file_download_ui.py\n", workflow)
        fixture = ROOT / "ios/tests/fixtures/local_direct_file_download_export_runtime.swift"
        self.assertTrue(fixture.exists())
        text = fixture.read_text() if fixture.exists() else ""
        self.assertIn("MobileLocalDirectFileDownloadDocument(data:", text)
        self.assertIn("MobileLocalDirectFileExportState()", text)
        self.assertNotIn("protocol FileDocument", text)


if __name__ == "__main__":
    unittest.main()
