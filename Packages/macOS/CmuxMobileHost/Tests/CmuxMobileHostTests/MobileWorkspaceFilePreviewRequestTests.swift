import Foundation
import Testing
@testable import CmuxMobileHost

struct MobileWorkspaceFilePreviewRequestTests {
    private let identifier = UUID(uuidString: "2B6D9163-FE8B-44B1-8509-2A62D96688E9")!
    private var params: [String: Any] {
        ["workspace_id": identifier.uuidString.lowercased(), "path": "literal%2e%2e/~", "root_id": String(repeating: "a", count: 64)]
    }

    @Test func literalPathsAndBoundariesWithoutIO() throws {
        for path in ["literal%2e%2e/~", "~/absent", "e\u{301}/中文", "a\\b", String(repeating: "x", count: 4096), String(repeating: "中", count: 1365) + "x"] {
            var values = params; values["path"] = path
            let request = try #require(MobileWorkspaceFilePreviewRequest(params: values))
            #expect(request.workspaceID == identifier)
            #expect(request.path.utf8.elementsEqual(path.utf8))
            #expect(request.rootID == String(repeating: "a", count: 64))
        }
        for marker in [String(repeating: "0", count: 64), String(repeating: "0123456789abcdef", count: 4)] {
            var values = params; values["root_id"] = marker
            #expect(MobileWorkspaceFilePreviewRequest(params: values)?.rootID == marker)
        }
    }

    @Test func exactRequiredKeysAndTypes() {
        for key in ["workspace_id", "path", "root_id"] {
            var values = params; values.removeValue(forKey: key)
            #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
            for value: Any in [NSNull(), true, false, 1, 1.5, [], ["value": "x"]] {
                values = params; values[key] = value
                #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
            }
        }
        for key in ["max", "max_bytes", "offset", "limit", "encoding", "auth", "authorization", "transport", "absolute_path", "root", "workspace_ref", "command", "initial_command", "unknown"] {
            var values = params; values[key] = NSNull()
            #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
        }
        for id in ["", "workspace:1", "not-a-uuid"] {
            var values = params; values["workspace_id"] = id
            #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
        }
    }

    @Test func rejectsUnsafePathsAndMarkers() throws {
        for path in ["", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a\0b", String(repeating: "x", count: 4097), String(repeating: "中", count: 1366)] {
            var values = params; values["path"] = path
            #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
        }
        for marker in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                       String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "é", count: 32)] {
            var values = params; values["root_id"] = marker
            #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
        }
        for raw in ["null", "true", "false", "64", "1.5", "[]", "{}"] {
            let data = Data("{\"workspace_id\":\"\(identifier)\",\"path\":\"file\",\"root_id\":\(raw)}".utf8)
            let values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(MobileWorkspaceFilePreviewRequest(params: values) == nil)
        }
    }
}
