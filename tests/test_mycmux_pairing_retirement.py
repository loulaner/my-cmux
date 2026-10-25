"""Source/wiring guards for retired Mac account pairing UI.

These checks do not launch GUI or verify authentication safety, Direct connections,
or iOS runtime behavior. The iOS selector deliberately shares the retired Mac name.
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAIRING = "Sources/Mobile/Pairing"
RETIRED_FILES = (
    "MobilePairingView.swift",
    "MobilePairingView+Connected.swift",
    "MobilePairingModel.swift",
)


class PairingRetirementTests(unittest.TestCase):
    def section(self, source, start, end):
        self.assertIn(start, source, f"Missing source boundary: {start}")
        remainder = source.split(start, 1)[1]
        self.assertIn(end, remainder, f"Missing source boundary after {start}: {end}")
        return remainder.split(end, 1)[0]

    def controller_source(self):
        return (ROOT / PAIRING / "MobilePairingWindowController.swift").read_text()

    def test_retired_mac_sources_are_absent(self):
        for name in RETIRED_FILES:
            relative = f"{PAIRING}/{name}"
            with self.subTest(path=relative):
                self.assertFalse((ROOT / relative).exists(), f"Retired source returned: {relative}")

    def test_project_does_not_wire_retired_mac_files(self):
        project = (ROOT / "cmux.xcodeproj/project.pbxproj").read_text()
        for name in RETIRED_FILES:
            with self.subTest(filename=name):
                self.assertNotIn(name, project)

    def test_window_constructs_direct_root(self):
        window = self.section(
            self.controller_source(),
            "override func makeWindow()",
            "override func managedWindowWillClose",
        )
        self.assertRegex(window, r"(?m)^\s*let\s+root\s*=\s*MobileLocalDirectView\(\s*\)")

    def test_panel_constructs_direct_view(self):
        panel = self.section(
            self.controller_source(),
            "struct MobilePairingPanelView: View {",
            "extension Workspace {",
        )
        self.assertRegex(panel, r"(?m)^\s*MobileLocalDirectView\(\s*\)")

    def test_both_close_entrypoints_delegate_to_direct_host(self):
        source = self.controller_source()
        window_close = self.section(
            source, "override func managedWindowWillClose", "\n    }"
        )
        panel = self.section(
            source, "final class MobilePairingPanel: Panel {", "struct MobilePairingPanelView: View {"
        )
        panel_close = self.section(panel, "func close()", "func triggerFlash")
        for entrypoint, body in (("window", window_close), ("panel", panel_close)):
            with self.subTest(entrypoint=entrypoint):
                self.assertRegex(
                    body,
                    r"(?m)^\s*(?:\{\s*)?MobileLocalDirectHostController\.shared\.closePairingWindow\(\s*\)",
                )

    def test_ios_same_named_selector_is_preserved(self):
        view = (ROOT / "Packages/iOS/CmuxMobileShellUI/Sources/CmuxMobileShellUI/PairingView.swift").read_text()
        self.assertIn('.accessibilityIdentifier("MobilePairingView")', view)
        ui_tests = (ROOT / "ios/cmuxUITests/cmuxUITests.swift").read_text()
        self.assertIn('app.descendants(matching: .any)["MobilePairingView"]', ui_tests)
        self.assertIn('visible: "MobilePairingView"', ui_tests)


if __name__ == "__main__":
    unittest.main()
