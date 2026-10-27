"""Source-only UI contract guard; not SwiftUI execution or device acceptance."""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"


def source(name):
    path = FEATURE / name
    return path.read_text() if path.exists() else ""


class LocalDirectFilesUIGuardTests(unittest.TestCase):
    def test_single_captured_sheet_and_independent_identity_retirement(self):
        root = source("MobileLocalDirectRootScene.swift")
        self.assertIn("private enum WorkspacePresentation: Identifiable", root)
        self.assertIn("@State private var workspacePresentation: WorkspacePresentation?", root)
        self.assertEqual(root.count(".sheet("), 1)
        self.assertIn(".sheet(item: $workspacePresentation)", root)
        for kind, model, view in [("changes", "MobileLocalDirectChangesSession", "MobileLocalDirectChangesView"),
                                  ("files", "MobileLocalDirectFilesSession", "MobileLocalDirectFilesView")]:
            self.assertIn(f"case {kind}({model})", root)
            self.assertIn(f"case .{kind}(let session): ObjectIdentifier(session)", root)
            self.assertIn(f"if let {kind}Session = controller.{kind}Session", root)
            self.assertIn(f"workspacePresentation = .{kind}({kind}Session)", root)
            self.assertIn(f"case .{kind}(let session):\n                {view}(session: session)", root)
            pattern = (rf"\.onChange\(of: controller\.{kind}Session.map.*?\n        \}}")
            handler = re.search(pattern, root, re.S)
            if handler is None:
                self.fail(f"Missing {kind} identity handler")
            self.assertIn(f"if case .{kind}(let session) = workspacePresentation", handler.group())
            self.assertIn("ObjectIdentifier(session) != identity", handler.group())
            self.assertIn("workspacePresentation = nil", handler.group())
            for forbidden in ["disconnect(", "invalidate(", "clear_all"]:
                self.assertNotIn(forbidden, handler.group())
        self.assertIn("ToolbarItemGroup(placement: .primaryAction)", root)
        self.assertNotIn("changesPresentation", root)
        self.assertNotIn("filesPresentation", root)

    def test_single_page_navigation_and_directory_only_actions(self):
        view = source("MobileLocalDirectFilesView.swift")
        for snippet in ["@Bindable var session: MobileLocalDirectFilesSession", "NavigationStack {", "List {",
                        "Text(verbatim: session.currentPath)", ".textCase(nil)", "if session.parentPath != nil",
                        "session.goToParent()", "ForEach(session.entries, id: \\.path)", "if entry.kind == .directory",
                        "session.openDirectory(path: entry.path)", "session.state != .ready || entry.path.utf8.count > 4_096",
                        "Text(verbatim: entry.name)", 'Image(systemName: "chevron.forward")', ".accessibilityHidden(true)",
                        ".accessibilityElement(children: .combine)", ".accessibilityHint(",
                        "ByteCountFormatter.string(fromByteCount: size, countStyle: .file)", "entry.kind == .file, let size = entry.size"]:
            self.assertIn(snippet, view)
        self.assertEqual(view.count("session.openDirectory("), 1)
        self.assertEqual(view.count("@State"), 3)
        self.assertIn("@State private var previewPresentation: PreviewPresentation?", view)
        self.assertIn("private struct PreviewPresentation: Hashable", view)
        self.assertIn("let session: MobileLocalDirectFilePreviewSession", view)
        self.assertIn("ObjectIdentifier(lhs.session) == ObjectIdentifier(rhs.session)", view)
        self.assertEqual(view.count(".navigationDestination("), 1)
        self.assertIn(".navigationDestination(item: $previewPresentation)", view)
        self.assertIn("MobileLocalDirectFilePreviewView(session: presentation.session)", view)
        self.assertRegex(view, r'else \{\s+entryLabel\(entry\)\s+\}')
        for forbidden in ["NavigationLink", "navigationPath", "TextField", "path: $", "appendingPathComponent"]:
            self.assertNotIn(forbidden, view)

    def test_explicit_loading_pagination_and_failure_recovery(self):
        view = source("MobileLocalDirectFilesView.swift")
        for snippet in [".task(id: ObjectIdentifier(session))", "guard !Task.isCancelled, session.state != .loading else { return }",
                        "case .idle, .loading:", "case .ready:", "if session.entries.isEmpty", "if session.nextOffset != nil",
                        "session.loadNextPage()", "case .failed(let failure):", "Text(failureMessage(failure))",
                        ".disabled(session.state == .loading)", "dismiss()"]:
            self.assertIn(snippet, view)
        self.assertEqual(view.count(".task("), 1)
        self.assertEqual(view.count("session.loadNextPage()"), 1)
        self.assertEqual(view.count("dismiss()"), 1)
        for failure in ["invalidSelection", "unsupported", "unsupportedWorkspace", "permissionDenied", "directoryUnavailable",
                        "directoryChanged", "limitExceeded", "invalidResponse", "unavailable", "disconnected"]:
            self.assertIn(f"case .{failure}:", view)
            self.assertIn(f'localized: "direct.files.error.{failure}"', view)
        self.assertIn('localized: "direct.files.metadataOnly"', view)
        self.assertEqual(view.count(".onChange("), 3)
        self.assertEqual(view.count(".onDisappear"), 1)
        self.assertIn("\n        .onDisappear { retireImport(); session.closeUpload(); session.closePreview() }", view)
        self.assertNotIn("\n            .onDisappear", view)
        self.assertIn("ObjectIdentifier(presentation.session) != identity", view)
        self.assertIn("if let old, new == nil, session.previewSession === old.session", view)
        for marker in ["session.previewSession.map", "previewPresentation"]:
            handler = re.search(r"\.onChange\(of: " + re.escape(marker) + r".*?\n        \}", view, re.S)
            if handler is None:
                self.fail("Missing identity/pop cleanup")
            for forbidden in ["refresh()", "disconnect(", "invalidate(", "openFile("]:
                self.assertNotIn(forbidden, handler.group())
        for forbidden in ["onAppear", "Timer", "Task.sleep", "refreshable", "prefetch"]:
            self.assertNotIn(forbidden, view)

    def test_metadata_only_no_connection_or_content_actions(self):
        view = source("MobileLocalDirectFilesView.swift")
        self.assertTrue(view)
        for forbidden in ["sendRequest", "MobileLocalDirectFilesSession(", "MobileLocalDirectFilePreviewSession(", "disconnect(", "session.invalidate(", "controller.invalidate(", "connection.invalidate(", "subscribe(",
                          "clear_all", "sendInput", "controller", "localizedDescription", "QuickLook", "WKWebView",
                          "Markdown", "AttributedString", "URL(", "openURL", "ShareLink", "UIPasteboard", "FileManager",
                          ".sheet(", "interactiveDismissDisabled", "UIScreen", "GeometryReader", "keyboard", "rootDirectory"]:
            self.assertNotIn(forbidden, view)
        self.assertEqual(re.findall(r"([A-Za-z_][A-Za-z_0-9]*\??)\.invalidate\(", view), ["importSession?"])
        self.assertEqual(view.count("guard importSession === selection else { return }"), 2)
        self.assertIn(".presentationDetents([.large])", view)
        self.assertIn("ToolbarItem(placement: .cancellationAction)", view)

    def test_dual_catalog_localization(self):
        ui = source("MobileLocalDirectRootScene.swift") + source("MobileLocalDirectFilesView.swift")
        keys = dict(re.findall(r'localized: "(direct\.files\.[^"]+)", defaultValue: "([^"]+)"', ui))
        self.assertEqual(len(keys), 21)
        catalogs = [json.loads((ROOT / p).read_text())["strings"] for p in
                    ["ios/cmux/Resources/Localizable.xcstrings", "Resources/Localizable.xcstrings"]]
        for key, english in keys.items():
            self.assertIn(key, catalogs[0])
            self.assertIn(key, catalogs[1])
            self.assertEqual(catalogs[0][key], catalogs[1][key])
            locales = catalogs[0][key]["localizations"]
            self.assertEqual(set(locales), {"en", "de", "fr", "ar", "es", "zh-Hant", "zh-Hans", "ko", "ja"})
            self.assertEqual(locales["en"]["stringUnit"]["value"], english)
            for locale, entry in locales.items():
                self.assertEqual(entry["stringUnit"]["state"], "translated")
                self.assertTrue(entry["stringUnit"]["value"])
                if locale != "en":
                    self.assertNotEqual(entry["stringUnit"]["value"], english)

    def test_linux_guard_lane(self):
        workflow = (ROOT / ".github/workflows/test-ios.yml").read_text()
        lane = workflow.split("  package-conventions-lint:", 1)[1].split("  mobile-core-package:", 1)[0]
        self.assertIn("- name: Guard local direct files UI wiring\n        run: python3 ios/tests/test_local_direct_files_ui.py", lane)
        self.assertLess(lane.index("Guard local direct changes UI wiring"), lane.index("Guard local direct files UI wiring"))


if __name__ == "__main__":
    unittest.main()
