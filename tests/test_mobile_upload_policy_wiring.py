"""Static guards for shared mobile upload policy wiring, not GUI or forced-MDM tests."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MobileUploadPolicyWiringTests(unittest.TestCase):
    def section(self, source, start, end):
        self.assertIn(start, source)
        remainder = source.split(start, 1)[1]
        self.assertIn(end, remainder)
        return remainder.split(end, 1)[0]

    def read(self, name):
        return (ROOT / "Sources" / name).read_text()

    def test_upload_refuses_before_feature_or_payload_work(self):
        body = self.section(
            self.read("TerminalController+MobileTaskAttachments.swift"),
            "func v2MobileTaskAttachmentUpload(params: [String: Any]) -> V2CallResult {",
            "\n    }",
        )
        self.assertRegex(
            body,
            r"^\s*if let error = Self\.mobileFileTransferPolicyError\(\)\s*\{\s*return error\s*\}"
            r"\s*guard Self\.mobileTaskComposerFeatureEnabled",
        )

    def test_image_refuses_before_base64_or_terminal_work(self):
        body = self.section(
            self.read("TerminalController.swift"),
            "func v2MobileTerminalPasteImage(params: [String: Any]) -> V2CallResult {",
            "\n    }",
        )
        self.assertRegex(
            body,
            r"^\s*if let error = Self\.mobileFileTransferPolicyError\(\)\s*\{\s*return error\s*\}"
            r'\s*guard let base64 = v2RawString\(params, "image_base64"\)',
        )

    def test_helper_default_reads_real_managed_policy(self):
        source = self.read("TerminalController+MobileTaskAttachments.swift")
        self.assertRegex(
            source,
            r"static func mobileFileTransferPolicyError\(\s*"
            r"isDisabled: Bool = ManagedFileTransferPolicy\.isDisabled\s*\) -> V2CallResult\?",
        )

    def test_mobile_rpc_aliases_share_guarded_bodies(self):
        source = self.read("TerminalController.swift")
        dispatch = self.section(source, "func mobileHostHandleRPC(", "func v2MobileTerminalPasteImage(")
        for case, call in (
            ('case "mobile.task.attachment.upload":', "v2MobileTaskAttachmentUpload"),
            ('case "mobile.terminal.paste_image", "terminal.paste_image":', "v2MobileTerminalPasteImage"),
        ):
            with self.subTest(case=case):
                branch = self.section(dispatch, case, "\n        case ")
                self.assertEqual(branch.strip(), f"result = {call}(params: request.params)")

    def test_control_upload_and_chat_image_share_guarded_bodies(self):
        control = self.section(
            self.read("TerminalController+ControlMobileHostContext.swift"),
            "func controlMobileTaskAttachmentUpload(",
            "\n    }",
        )
        self.assertIn("v2MobileTaskAttachmentUpload(params: foundationParams(params))", control)
        chat = self.section(
            self.read("TerminalController+MobileChat.swift"),
            "func v2MobileChatSend(params:",
            "\n    }",
        )
        self.assertIn("let result = v2MobileTerminalPasteImage(params: imageParams)", chat)
        self.assertRegex(chat, r"if case \.err = result\s*\{\s*return result\s*\}")


if __name__ == "__main__":
    unittest.main()
