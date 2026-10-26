import Foundation
import Testing
@testable import CmuxMobileHost

struct MobileWorkspaceFileListRequestTests {
    private let identifier = UUID(uuidString: "2B6D9163-FE8B-44B1-8509-2A62D96688E9")!

    @Test func defaultsAndLiteralPaths() throws {
        let parsed = try #require(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString.lowercased()]))
        #expect(parsed.workspaceID == identifier && parsed.path == "" && parsed.offset == 0 && parsed.limit == 100)
        for path in ["", "a/b", "%2e%2e", "~/literal", "中文 []", String(repeating: "x", count: 4096)] {
            let request = try #require(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString,
                "path": path, "offset": Int.max, "limit": 1]))
            #expect(request.path == path && request.offset == Int.max && request.limit == 1)
        }
    }

    @Test func strictFieldsAndPaths() {
        #expect(MobileWorkspaceFileListRequest(params: [:]) == nil)
        for value: Any in [NSNull(), 1, true, "", "workspace:1", "not-a-uuid"] {
            #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": value]) == nil)
        }
        for value: Any in [NSNull(), 1, true, [], "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a\0b",
                           String(repeating: "x", count: 4097), String(repeating: "中", count: 1366)] {
            #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString, "path": value]) == nil)
        }
        for key in ["command", "initial_command", "tmux_start_command", "pane_start_command", "absolute_path",
                    "root", "directory", "auth", "transport", "workspace_ref", "unknown"] {
            #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString, key: NSNull()]) == nil)
        }
    }

    @Test func strictIntegerBoundaries() throws {
        for field in ["offset", "limit"] {
            for value: Any in [true, false, NSNumber(value: true), NSNull(), -1, 1.5, "1", [], ["value": 1]] {
                #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString, field: value]) == nil)
            }
            for value: Any in [1, 100, NSNumber(value: 2)] {
                #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString, field: value]) != nil)
            }
            for (value, valid) in [("true", false), ("false", false), ("1.5", false), ("null", false),
                                   ("\"1\"", false), ("1", true), ("100", true)] {
                let params = try #require(JSONSerialization.jsonObject(with: Data(
                    "{\"workspace_id\":\"\(identifier)\",\"\(field)\":\(value)}".utf8)) as? [String: Any])
                #expect((MobileWorkspaceFileListRequest(params: params) != nil) == valid)
            }
        }
        for value in [0, 101, Int.max] {
            #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString, "limit": value]) == nil)
        }
        for value in [0, 101, Int.max] {
            #expect(MobileWorkspaceFileListRequest(params: ["workspace_id": identifier.uuidString, "offset": value]) != nil)
        }
    }
}
