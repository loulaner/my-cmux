"""Source guard only: does not run SwiftUI, authentication, or device behavior."""
import hashlib
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"


def source(name):
    path = FEATURE / name
    return path.read_text() if path.exists() else ""


class LocalDirectChangesUIGuardTests(unittest.TestCase):
    def test_captured_capability_entry_and_identity_dismissal(self):
        root = source("MobileLocalDirectRootScene.swift")
        self.assertIn("if let changesSession = controller.changesSession", root)
        self.assertIn("workspacePresentation = .changes(changesSession)", root)
        self.assertIn("private enum WorkspacePresentation: Identifiable", root)
        self.assertIn("case changes(MobileLocalDirectChangesSession)", root)
        self.assertIn(".sheet(item: $workspacePresentation)", root)
        self.assertIn("case .changes(let session):\n                MobileLocalDirectChangesView(session: session)", root)
        self.assertIn("case .changes(let session): ObjectIdentifier(session)", root)
        self.assertIn(".onChange(of: controller.changesSession.map { ObjectIdentifier($0) })", root)
        self.assertIn("if case .changes(let session) = workspacePresentation, ObjectIdentifier(session) != identity", root)
        self.assertIn("workspacePresentation = nil", root)
        self.assertEqual(root.count(".sheet("), 1)
        self.assertIn("ToolbarItemGroup(placement: .primaryAction)", root)

    def test_list_and_detail_request_lifetimes(self):
        view = source("MobileLocalDirectChangesView.swift")
        self.assertIn("@Bindable var session: MobileLocalDirectChangesSession", view)
        self.assertIn("NavigationStack(path: $navigationPath)", view)
        self.assertIn(".task(id: ObjectIdentifier(session))", view)
        self.assertIn("!Task.isCancelled, session.filesState != .loading", view)
        self.assertIn("navigationPath.removeAll()\n        session.refresh()", view)
        self.assertIn(".disabled(session.filesState == .loading)", view)
        self.assertIn("ForEach(response.files, id: \\.path)", view)
        self.assertIn("NavigationLink(value: file.path)", view)
        self.assertIn(".navigationDestination(for: String.self)", view)
        self.assertIn(".task(id: path)", view)
        self.assertIn("guard !Task.isCancelled else { return }", view)
        self.assertIn("session.selectFile(path: path)", view)
        self.assertEqual(view.count("session.refresh()"), 1)
        self.assertEqual(view.count(".task("), 2)
        self.assertEqual(view.count("dismiss()"), 1)

    def test_plain_bounded_content_and_safe_states(self):
        view = source("MobileLocalDirectChangesView.swift")
        for snippet in ["session.selectedPath == path", "diff.path == path", "Text(verbatim: diff.unifiedDiff)",
                        "Text(verbatim: file.path)", "Text(verbatim: oldPath)", "Text(verbatim: path)",
                        "ScrollView([.horizontal, .vertical])", ".font(.system(.body, design: .monospaced))",
                        ".textSelection(.enabled)", "if diff.isBinary", "if response.truncated", "if diff.truncated",
                        "case .idle, .loading:", "case .ready:", "case .failed(let failure):"]:
            self.assertIn(snippet, view)
        for failure in ["invalidSelection", "unsupported", "notRepository", "permissionDenied", "invalidResponse", "unavailable", "disconnected"]:
            self.assertIn(f"case .{failure}:", view)
            self.assertIn(f'localized: "direct.changes.error.{failure}"', view)
        for forbidden in ["sendRequest", "MobileLocalDirectChangesSession(", "disconnect(", "invalidate(", "subscribe(",
                          "clear_all", "sendInput", "repoRoot", "contentFingerprint", "localizedDescription", "WKWebView",
                          "AttributedString", "Markdown", "openURL", "URL(", ".sheet(", "Timer", "Task.sleep",
                          "onDisappear", "interactiveDismissDisabled", "UIScreen"]:
            self.assertNotIn(forbidden, view)
        self.assertNotIn("controller", view)

    def test_dual_catalog_nine_locale_parity(self):
        ui = source("MobileLocalDirectRootScene.swift") + source("MobileLocalDirectChangesView.swift")
        keys = dict(re.findall(r'localized: "(direct\.changes\.[^"]+)", defaultValue: "([^"]+)"', ui))
        self.assertEqual(len(keys), 17)
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
        self.assertIn("- name: Guard local direct changes UI wiring\n        run: python3 ios/tests/test_local_direct_changes_ui.py", lane)
        self.assertLess(lane.index("Guard removed iOS purchasing capability"), lane.index("Guard local direct changes UI wiring"))

    def test_original_terminal_renderer_and_methods_unchanged(self):
        root = source("MobileLocalDirectRootScene.swift")
        renderer = root.split("                    if let session = controller.terminalSession {", 1)[1].split('.navigationTitle(selectedTitle ?? "")', 1)[0]
        methods = root[root.index("    private func terminalStatus("):]
        self.assertEqual(hashlib.sha256(renderer.encode()).hexdigest(), "9df0085cfc5ec83f044fd3100c4bab149683da317ffd2c09954e02c0c69e093f")
        self.assertEqual(hashlib.sha256(methods.encode()).hexdigest(), "0d6143ab827951253e8b454f46498d66753d64cea694dd22b939b8b2fcf3463e")


if __name__ == "__main__":
    unittest.main()
