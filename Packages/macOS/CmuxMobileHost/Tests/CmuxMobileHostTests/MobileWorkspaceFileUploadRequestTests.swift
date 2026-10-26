import Foundation
import Testing
@testable import CmuxMobileHost

struct MobileWorkspaceFileUploadRequestTests {
    private func parameters(_ data: Data = Data()) -> [String: Any] {
        ["workspace_id": "2b6d9163-fe8b-44b1-8509-2a62d96688e9", "path": "", "root_id": String(repeating: "a", count: 64),
         "file_name": "file", "data_base64": data.base64EncodedString(), "byte_count": data.count,
         "sha256": String(repeating: "b", count: 64)]
    }

    @Test(arguments: [0, 3, 256, 2_097_152]) func completeBytes(_ size: Int) throws {
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
        let request = try #require(MobileWorkspaceFileUploadRequest(params: parameters(data)))
        #expect(request.data == data)
        #expect(request.relativePath == "file")
        #expect(request.workspaceID.uuidString == "2B6D9163-FE8B-44B1-8509-2A62D96688E9")
        // Correct-format but incorrect digest is deliberately accepted here; the service hashes independently.
        #expect(request.sha256 == String(repeating: "b", count: 64))
    }

    @Test(arguments: ["workspace_id", "path", "root_id", "file_name", "data_base64", "byte_count", "sha256"])
    func requiredFields(_ key: String) {
        var params = parameters(); params.removeValue(forKey: key)
        #expect(MobileWorkspaceFileUploadRequest(params: params) == nil)
        for value: Any in [NSNull(), true, [], [:]] {
            params = parameters(); params[key] = value
            #expect(MobileWorkspaceFileUploadRequest(params: params) == nil)
        }
        if key != "byte_count" {
            params = parameters(); params[key] = 1
            #expect(MobileWorkspaceFileUploadRequest(params: params) == nil)
        }
    }

    @Test(arguments: ["auth", "trust", "offset", "overwrite", "absolute_path", "limit", "command"])
    func extraKeys(_ key: String) {
        var params = parameters(); params[key] = false
        #expect(MobileWorkspaceFileUploadRequest(params: params) == nil)
    }

    @Test func invalidValues() {
        let cases: [(String, [Any])] = [
            ("workspace_id", ["", "garbage"]),
            ("path", ["/abs", "a/", "a//b", ".", "..", "a/../b", "a\0b", String(repeating: "a", count: 4_096)]),
            ("file_name", ["", ".", "..", "a/b", "a\\b", "a\0b", "a\nb", "a\u{7f}b", String(repeating: "é", count: 128)]),
            ("root_id", ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64)]),
            ("sha256", ["", String(repeating: "B", count: 64), String(repeating: "b", count: 65), String(repeating: "é", count: 32)]),
            ("byte_count", ["0", -1, 0.5, NSNumber(value: UInt64.max), NSNumber(value: Double.infinity), 2_097_153, 1]),
            ("data_base64", [" ", "\n", "AA", "AA=", "AB==", "AA==\n", "-_==", "!!!!", String(repeating: "A", count: 2_796_205)]),
        ]
        for (key, values) in cases {
            for value in values {
                var params = parameters(); params[key] = value
                #expect(MobileWorkspaceFileUploadRequest(params: params) == nil, "\(key)")
            }
        }
        var over = parameters(Data(repeating: 0, count: 2_097_153))
        #expect(MobileWorkspaceFileUploadRequest(params: over) == nil)
        over["byte_count"] = 2_097_152
        #expect(MobileWorkspaceFileUploadRequest(params: over) == nil)
        var padBits = parameters(Data([0])); padBits["data_base64"] = "AB=="
        #expect(MobileWorkspaceFileUploadRequest(params: padBits) == nil)
    }

    @Test(arguments: ["literal%2e%2e/~", "e\u{301}/中文", "a\\b", ""])
    func literalPaths(_ path: String) throws {
        var params = parameters(); params["path"] = path; params["file_name"] = "%~中文e\u{301}"
        let request = try #require(MobileWorkspaceFileUploadRequest(params: params))
        #expect(request.path.utf8.elementsEqual(path.utf8))
        #expect(request.relativePath.utf8.elementsEqual((path.isEmpty ? "%~中文e\u{301}" : path + "/%~中文e\u{301}").utf8))
    }

    @Test func exactBoundsAndNumericValue() throws {
        var params = parameters(); params["file_name"] = String(repeating: "x", count: 255)
        params["path"] = String(repeating: "d", count: 3_840)
        #expect(try #require(MobileWorkspaceFileUploadRequest(params: params)).relativePath.utf8.count == 4_096)
        params["path"] = String(repeating: "d", count: 3_841)
        #expect(MobileWorkspaceFileUploadRequest(params: params) == nil)
        params = parameters(); params["byte_count"] = NSNumber(value: 0.0)
        #expect(MobileWorkspaceFileUploadRequest(params: params) != nil)
    }
}
