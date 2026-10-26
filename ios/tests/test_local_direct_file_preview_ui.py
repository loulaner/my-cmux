"""Source wiring guard only: no SwiftUI lifecycle, gesture or device execution."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"


def source(name):
    path = FEATURE / name
    return path.read_text() if path.exists() else ""


def block(text, marker):
    """Extract a known source block, failing normally when baseline wiring is absent."""
    start = text.find(marker)
    if start < 0:
        return ""
    opening = text.find("{", start + len(marker))
    depth = 1
    end = opening + 1
    while opening >= 0 and end < len(text) and depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end] if opening >= 0 and depth == 0 else ""


class LocalDirectFilePreviewUIGuardTests(unittest.TestCase):
    def test_captured_identity_destination_and_regular_file_gate(self):
        view = source("MobileLocalDirectFilesView.swift")
        for snippet in ["@State private var previewPresentation: PreviewPresentation?",
                        "private struct PreviewPresentation: Hashable", "let session: MobileLocalDirectFilePreviewSession",
                        "ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)", "hasher.combine(ObjectIdentifier(session))",
                        ".navigationDestination(item: $previewPresentation)",
                        "MobileLocalDirectFilePreviewView(session: presentation.session)",
                        "else if entry.kind == .file && session.canOpenFiles",
                        "if session.openFile(path: entry.path), let child = session.previewSession",
                        "previewPresentation = PreviewPresentation(session: child)",
                        ".disabled(entry.path.utf8.count > 4_096)"]:
            self.assertIn(snippet, view)
        self.assertEqual(view.count("NavigationStack {"), 1)
        self.assertEqual(view.count(".navigationDestination("), 1)
        self.assertEqual(view.count("@State"), 1)
        self.assertNotIn("navigationPath", view)
        self.assertNotIn("MobileLocalDirectFilePreviewSession(", view)
        self.assertNotIn("controller", view)
        self.assertRegex(view, r"else \{\s+entryLabel\(entry\)\s+\}")
        notice = block(view, "if session.state == .ready")
        self.assertIn("if session.canOpenFiles", notice)
        self.assertIn('localized: "direct.preview.availability"', notice)
        self.assertIn('localized: "direct.files.metadataOnly"', notice)

    def test_pop_and_owner_exit_retire_only_captured_child(self):
        view = source("MobileLocalDirectFilesView.swift")
        self.assertEqual(view.count(".onChange("), 2)
        identity = re.search(r"\.onChange\(of: session.previewSession.map.*?\n        \}", view, re.S)
        if identity is None:
            self.fail("Missing preview owner identity retirement")
        self.assertIn("ObjectIdentifier(presentation.session) != identity", identity.group())
        self.assertIn("previewPresentation = nil", identity.group())
        pop = block(view, ".onChange(of: previewPresentation)")
        self.assertIn("if let old, new == nil, session.previewSession === old.session", pop)
        self.assertEqual(pop.count("session.closePreview()"), 1)
        for handler in [identity.group(), pop]:
            for forbidden in ["refresh()", "invalidate(", "disconnect(", "openFile("]:
                self.assertNotIn(forbidden, handler)
        self.assertEqual(view.count(".onDisappear"), 1)
        self.assertIn("\n        .onDisappear { session.closePreview() }", view)
        stack = block(view, "NavigationStack")
        self.assertNotIn(".onDisappear", stack)
        self.assertIn("session.closePreview(); dismiss()", stack)
        self.assertEqual(view.count(".task("), 1)
        self.assertIn(".task(id: ObjectIdentifier(session))", view)
        self.assertEqual(view.count("session.refresh()"), 3)
        self.assertNotIn(".onDisappear", source("MobileLocalDirectFilePreviewView.swift"))

    def test_detail_is_plain_bounded_model_text(self):
        view = source("MobileLocalDirectFilePreviewView.swift")
        self.assertTrue(view)
        for snippet in ["@MainActor", "@Bindable var session: MobileLocalDirectFilePreviewSession", "ScrollView {",
                        "VStack(alignment: .leading", "Text(verbatim: session.path)", "Text(verbatim: text)",
                        ".font(.body.monospaced())", ".textSelection(.enabled)",
                        ".fixedSize(horizontal: false, vertical: true)", ".frame(maxWidth: .infinity, alignment: .leading)",
                        "if let text = session.text, let totalBytes = session.totalBytes", "if text.isEmpty",
                        "Int64(session.displayedByteCount)", "ByteCountFormatter.string(fromByteCount:", "countStyle: .file",
                        "if session.truncated", "failureMessage(.invalidResponse)", ".navigationTitle(Text(verbatim:"]:
            self.assertIn(snippet, view)
        self.assertEqual(view.count("ScrollView {"), 1)
        for forbidden in ["@State", "NavigationStack", ".sheet(", "NavigationLink", "navigationDestination", "TextEditor",
                          "Markdown", "AttributedString", "WebView", "QuickLook", "Image(", "URL(", "openURL", "ShareLink",
                          "UIPasteboard", "FileManager", "sendRequest", "disconnect(", "invalidate(", "closePreview(", "controller",
                          "localizedDescription", "data_base64", "Data(", ".horizontal", "interactiveDismissDisabled", "navigationBarBackButtonHidden"]:
            self.assertNotIn(forbidden, view)

    def test_only_idle_mount_and_explicit_retry_refresh(self):
        view = source("MobileLocalDirectFilePreviewView.swift")
        self.assertIn(".task(id: ObjectIdentifier(session))", view)
        self.assertIn("guard !Task.isCancelled, session.state == .idle else { return }", view)
        self.assertEqual(view.count(".task("), 1)
        self.assertEqual(view.count("session.refresh()"), 3)
        for forbidden in ["onAppear", "onChange", "onDisappear", "Timer", "Task.sleep", "refreshable", "subscribe("]:
            self.assertNotIn(forbidden, view)
        self.assertIn(".disabled(session.state == .loading || !canRetry)", view)
        retry = block(view, "private var canRetry: Bool")
        self.assertIn("case .failed(.directoryChanged), .failed(.disconnected): false", retry)
        self.assertIn("if canRetry", view)
        for failure in ["invalidSelection", "unsupported", "unsupportedWorkspace", "permissionDenied", "fileUnavailable",
                        "directoryChanged", "fileChanged", "unsupportedContent", "invalidResponse", "unavailable", "disconnected"]:
            self.assertIn(f"case .{failure}:", view)
            self.assertIn(f'localized: "direct.preview.error.{failure}"', view)
        self.assertIn("Workspace folder changed. Go back and refresh the folder.", view)
        self.assertIn("Reconnect", view)
        self.assertIn("ToolbarItem(placement: .primaryAction)", view)
        self.assertNotIn(".cancellationAction", view)

    def test_all_preview_strings_match_both_nine_locale_catalogs(self):
        ui = source("MobileLocalDirectFilesView.swift") + source("MobileLocalDirectFilePreviewView.swift")
        pairs = re.findall(r'localized: "(direct\.preview\.[^"]+)", defaultValue: "([^"]+)"', ui)
        keys = dict(pairs)
        self.assertEqual(len(keys), 18)
        self.assertEqual(len(pairs), len(keys))
        catalogs = [json.loads((ROOT / p).read_text())["strings"] for p in
                    ["ios/cmux/Resources/Localizable.xcstrings", "Resources/Localizable.xcstrings"]]
        for catalog in catalogs:
            self.assertEqual({key for key in catalog if key.startswith("direct.preview.")}, set(keys))
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

    def test_workflow_adjacent_guard(self):
        workflow = (ROOT / ".github/workflows/test-ios.yml").read_text()
        self.assertIn("      - name: Guard local direct files UI wiring\n        run: python3 ios/tests/test_local_direct_files_ui.py\n\n"
                      "      - name: Guard local direct file preview UI wiring\n        run: python3 ios/tests/test_local_direct_file_preview_ui.py\n", workflow)


if __name__ == "__main__":
    unittest.main()
