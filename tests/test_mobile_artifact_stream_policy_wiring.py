"""Source/wiring guards only: no real MDM, files, QUIC, or app lifecycle tests."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REFUSAL = r"if let error = Self\.mobileFileTransferPolicyError\(\)\s*\{\s*return error\s*\}"
CHECK = r"try await registry\.checkFileTransferPolicy\(\)"


class MobileArtifactStreamPolicyWiringTests(unittest.TestCase):
    def section(self, source, start, end):
        self.assertIn(start, source)
        rest = source.split(start, 1)[1]
        self.assertIn(end, rest)
        return rest.split(end, 1)[0]

    def router(self):
        return (ROOT / "Sources/Mobile/MobileHostIrohApplicationLaneRouter.swift").read_text()

    def test_fetch_guards_and_original_descriptor_delegation(self):
        for area, name, wire, count in (
            ("MobileTerminalArtifacts", "Terminal", "TerminalArtifactWire.result", 3),
            ("MobileChatArtifacts", "Chat", "ChatArtifactWire.result", 3),
            ("MobileSurfaces", "Panel", "mobilePanelArtifactResult", 2),
        ):
            with self.subTest(area=area):
                source = (ROOT / f"Sources/TerminalController+{area}.swift").read_text()
                method = self.section(source, f"func v2Mobile{name}ArtifactFetch(", "\n    }")
                body = method.split(") async -> V2CallResult {", 1)[1]
                self.assertRegex(body, r"^\s*" + REFUSAL + r"\s*let resolution")
                if name != "Panel":
                    self.assertRegex(body, r"return resolution\.failureResult\s*\}\s*" + REFUSAL + r"\s*let offset")
                self.assertEqual(body.count("Self.mobileFileTransferPolicyError()"), count)
                self.assertRegex(body, r"\}\.value\s*" + REFUSAL + r"\s*return " + re.escape(wire) + r"\(chunk\)")
                self.assertRegex(body, r"return " + re.escape(wire) + r"\(\s*try await executionContext\.issueArtifactTransfer\(")
                self.assertIn("guard let executionContext else", body)
                first_catch = body.split("} catch", 1)[1]
                self.assertRegex(first_catch, r"^ where ManagedFileTransferPolicy\.isRefusal\(error\)\s*\{\s*return Self\.mobileFileTransferDisabledResult")
                self.assertIn("catch let error as MobileHostIrohArtifactTransferRegistry.Error", body)

    def test_shared_nonoptional_refusal_preserves_occurred_error(self):
        source = (ROOT / "Sources/TerminalController+MobileTaskAttachments.swift").read_text()
        result = self.section(source, "static var mobileFileTransferDisabledResult: V2CallResult {", "\n    }")
        self.assertIn('return .err(code: "file_transfer_disabled", message: ManagedFileTransferPolicy.disabledMessage, data: nil)', result)
        helper = self.section(source, "static func mobileFileTransferPolicyError(", "\n    }")
        self.assertIn("isDisabled: Bool = ManagedFileTransferPolicy.isDisabled", helper)
        self.assertRegex(helper, r"guard isDisabled else \{ return nil \}\s*return mobileFileTransferDisabledResult")

    def test_registry_reads_live_policy_before_issue_and_claim_mutation(self):
        registry = self.section(self.router(), "actor MobileHostIrohArtifactTransferRegistry {", "\nstruct MobileHostIrohArtifactFileIdentity")
        self.assertIn("private let isFileTransferDisabled: @Sendable () -> Bool", registry)
        self.assertRegex(registry, r"isFileTransferDisabled: @escaping @Sendable \(\) -> Bool = \{ ManagedFileTransferPolicy\.isDisabled \}")
        self.assertIn("self.isFileTransferDisabled = isFileTransferDisabled", registry)
        checker = self.section(registry, "func checkFileTransferPolicy() throws {", "\n    }")
        self.assertRegex(checker, r"^\s*if isFileTransferDisabled\(\)\s*\{\s*throw ManagedFileTransferPolicy\.refusalError\(\)\s*\}\s*$")
        for method, result in (("issue", "ChatArtifactLaneDescriptor"), ("claim", "Lease")):
            with self.subTest(method=method):
                body = self.section(registry, f"func {method}(", "\n    }").split(f") throws -> {result} {{", 1)[1]
                self.assertRegex(body, r"^\s*try checkFileTransferPolicy\(\)\s*let currentTime = now\(\)")

    def test_owned_handler_checks_reader_read_send_and_finish_boundaries(self):
        handler = self.section(self.router(), "struct MobileHostIrohArtifactLaneHandler:", "\n/// Separate credits")
        body = self.section(handler, ") async -> Bool {", "\n    }")
        self.assertEqual(body.count("try await registry.checkFileTransferPolicy()"), 4)
        self.assertRegex(body, r"\} catch \{\s*return false\s*\}\s*do \{\s*" + CHECK + r"\s*let reader = try MobileHostIrohArtifactDispatchReader")
        self.assertRegex(body, r"while readOffset < totalSize \{\s*try Task\.checkCancellation\(\)\s*" + CHECK + r"\s*let remainingByteCount")
        self.assertRegex(body, r"guard !data\.isEmpty else \{\s*throw MobileHostIrohArtifactTransferRegistry\.Error\.invalidFile\s*\}\s*try Task\.checkCancellation\(\)\s*" + CHECK + r"\s*try await stream\.sendStream\.send\(data\)")
        self.assertRegex(body, r"guard try reader\.snapshot\(\) == lease\.identity else \{\s*throw MobileHostIrohArtifactTransferRegistry\.Error\.invalidFile\s*\}\s*" + CHECK + r"\s*try await stream\.sendStream\.finish\(\)")
        self.assertIn("defer { reader.close() }", body)
        self.assertRegex(body, r"catch is CancellationError \{\s*await stream\.sendStream\.reset\(errorCode: 0\)\s*await stream\.receiveStream\.stop\(errorCode: 0\)")
        self.assertRegex(body, r"\} catch \{\s*await stream\.sendStream\.reset\(errorCode: Self\.streamFailureCode\)\s*await stream\.receiveStream\.stop\(errorCode: Self\.streamFailureCode\)\s*\}\s*await registry\.release\(lease\)\s*return true")
        self.assertIn("private static let streamFailureCode: UInt64 = 6", handler)
        self.assertIn("private static let chunkByteCount = 64 * 1_024", handler)


if __name__ == "__main__":
    unittest.main()
