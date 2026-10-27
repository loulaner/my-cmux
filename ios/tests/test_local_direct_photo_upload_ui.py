"""Source guard only; not execution of the system Photos picker/provider."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"
SHELL = ROOT / "Packages/iOS/CmuxMobileShell/Sources/CmuxMobileShell"


def read(path):
    return path.read_text() if path.exists() else ""


class LocalDirectPhotoUploadUIGuardTests(unittest.TestCase):
    def test_bounded_import_only_transfer(self):
        source = read(SHELL / "MobileLocalDirectPhotoTransfer.swift")
        self.assertIn("public import CoreTransferable", source)
        self.assertIn("Transferable, Sendable", source)
        self.assertIn("public let selection: MobileLocalDirectFileImportReader.Selection", source)
        self.assertIn("FileRepresentation(importedContentType: .image", source)
        self.assertIn("try await importFile(received.file)", source)
        self.assertIn("try await reader.read(url)", source)
        for forbidden in ["DataRepresentation", "exporting:", "UIImage", "copyItem", "write(", "Data(contentsOf:", "unchecked Sendable"]:
            self.assertNotIn(forbidden, source)

    def test_single_current_picker_captured_identity_and_item_release(self):
        source = read(FEATURE / "MobileLocalDirectPhotoPickerView.swift")
        self.assertIn("import PhotosUI", source)
        self.assertIn("@State private var item: PhotosPickerItem?", source)
        self.assertIn("isPresented: $selection.isPickerPresented", source)
        self.assertIn("selection: $item, matching: .images, preferredItemEncoding: .current", source)
        self.assertEqual(source.count(".onChange("), 1)
        self.assertIn("guard let item else { return }", source)
        self.assertLess(source.index("self.item = nil"), source.index("guard isCurrent()"))
        self.assertIn("selection.select(load:", source)
        self.assertIn("item.loadTransferable(type: MobileLocalDirectPhotoTransfer.self)", source)
        self.assertIn("return payload.selection", source)
        for forbidden in ["Data.self", "UIImage", "PHAsset", "assetIdentifier", "requestAuthorization", "PhotoLibrary",
                          ".task", ".onDisappear", "onChange(of: selection.isPickerPresented", ".start()", "queuePath", "sendRequest"]:
            self.assertNotIn(forbidden, source)
        files = read(FEATURE / "MobileLocalDirectFilesView.swift")
        for text in ["switch selection.source", "case .file:", "case .photo:", "MobileLocalDirectPhotoPickerView(selection: selection)",
                     "[selection] in", "importSession === selection", ".id(ObjectIdentifier(selection))", "source: .photo"]:
            self.assertIn(text, files)
        for name in ["MobileLocalDirectFilesView.swift", "MobileLocalDirectFileUploadView.swift"]:
            self.assertIn("importSession?.isBusy == true", read(FEATURE / name))

    def test_shared_model_and_explicit_upload(self):
        model = read(SHELL / "MobileLocalDirectFileImportSession.swift")
        self.assertIn("public enum Source", model)
        self.assertIn("public let source: Source", model)
        self.assertIn("source: Source = .file", model)
        self.assertIn("source == .file || isPickerPresented", model)
        self.assertIn("public func select(load:", model)
        self.assertIn("select(load: { try await read(url) })", model)
        self.assertEqual(model.count("files.prepareUpload("), 1)
        self.assertEqual(model.count("requestTask = Task"), 1)
        upload = read(FEATURE / "MobileLocalDirectFileUploadView.swift")
        self.assertIn("let choosePhoto: () -> Void", upload)
        self.assertIn('defaultValue: "Choose Photo…"), action: choosePhoto)', upload)
        self.assertEqual(upload.count("child.start()"), 1)

    def test_catalogs_and_workflow(self):
        expected = {"direct.upload.choosePhoto": "Choose Photo…",
                    "direct.upload.photoHint": "Select one image up to 2 MiB. This app doesn't resize or convert it."}
        catalogs = [json.loads((ROOT / p).read_text())["strings"] for p in
                    ["Resources/Localizable.xcstrings", "ios/cmux/Resources/Localizable.xcstrings"]]
        for key, english in expected.items():
            self.assertIn(key, catalogs[0])
            self.assertEqual(catalogs[0][key], catalogs[1][key])
            rows = catalogs[0][key]["localizations"]
            self.assertEqual(set(rows), {"en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"})
            for locale, row in rows.items():
                self.assertEqual(row["stringUnit"]["state"], "translated")
                self.assertTrue(row["stringUnit"]["value"])
                if locale == "en":
                    self.assertEqual(row["stringUnit"]["value"], english)
        workflow = (ROOT / ".github/workflows/test-ios.yml").read_text()
        self.assertIn("      - name: Guard local direct photo upload UI wiring\n        run: python3 ios/tests/test_local_direct_photo_upload_ui.py", workflow)


if __name__ == "__main__":
    unittest.main()
