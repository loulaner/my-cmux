import Testing
@testable import CmuxIrxTransport

@Suite("Local peer authorization")
struct IrxLocalPeerJudgeTests {
    private let key = String(repeating: "ab", count: 32)
    private let otherKey = String(repeating: "cd", count: 32)

    private func authorization(
        key: String? = nil, revoked: Bool = false, generation: Int = 7
    ) throws -> IrxLocalPeerAuthorization {
        try IrxLocalPeerAuthorization(
            endpointIDHex: key ?? self.key, bindingID: " binding ",
            deviceID: " device\n", tag: " tag ", identityGeneration: generation,
            revoked: revoked
        )
    }

    @Test func defaultDenialAndForgedGrant() throws {
        let judge = IrxLocalPeerJudge(current: IrxLocalPeerAuthorizationCurrent()).judgment()
        for grant: String? in [nil, "forged.grant.signature"] {
            #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) {
                try judge(grant, key)
            }
        }
    }

    @Test func exactTupleAndCaseNormalization() throws {
        let current = IrxLocalPeerAuthorizationCurrent()
        try current.replace([authorization(key: key.uppercased())])
        let judge = IrxLocalPeerJudge(current: current).judgment()
        let expected = IrxAdmittedPeerInfo(
            bindingID: "binding", deviceID: "device", tag: "tag",
            endpointIDHex: key, identityGeneration: 7
        )
        #expect(try judge(nil, key.uppercased()) == expected)
        #expect(try judge("forged.grant.signature", key) == expected)
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judge(nil, otherKey) }
    }

    @Test(arguments: ["", "ab", String(repeating: "a", count: 63),
                      String(repeating: "a", count: 65), String(repeating: "g", count: 64),
                      String(repeating: "Ａ", count: 64), " " + String(repeating: "a", count: 64)])
    func invalidKeys(key: String) throws {
        #expect(throws: IrxLocalPeerAuthorization.ValidationError.invalidEndpointID) {
            try authorization(key: key)
        }
        let current = IrxLocalPeerAuthorizationCurrent()
        try current.replace([authorization()])
        let judge = IrxLocalPeerJudge(current: current).judgment()
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judge(nil, key) }
    }

    @Test func invalidTupleFields() {
        for fields in [(" \n", "device", "tag", 1), ("binding", "\t", "tag", 1),
                       ("binding", "device", " ", 1), ("binding", "device", "tag", 0),
                       ("binding", "device", "tag", -1)] {
            #expect(throws: IrxLocalPeerAuthorization.ValidationError.self) {
                try IrxLocalPeerAuthorization(
                    endpointIDHex: key, bindingID: fields.0, deviceID: fields.1,
                    tag: fields.2, identityGeneration: fields.3, revoked: false
                )
            }
        }
        #expect(throws: Never.self) { try authorization(generation: 1) }
    }

    @Test func duplicateReplacementPreservesSnapshot() throws {
        let current = IrxLocalPeerAuthorizationCurrent()
        let original = try authorization()
        try current.replace([original])
        #expect(throws: IrxLocalPeerAuthorizationCurrent.ReplacementError.duplicateEndpointID) {
            try current.replace([authorization(key: otherKey), authorization(key: otherKey.uppercased(), revoked: true)])
        }
        #expect(current.current == [key: original])
    }

    @Test func existingClosureObservesAdditionRevocationClearAndRotation() throws {
        let current = IrxLocalPeerAuthorizationCurrent()
        let judge = IrxLocalPeerJudge(current: current).judgment()
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judge(nil, key) }
        try current.replace([authorization()])
        #expect(try judge(nil, key).identityGeneration == 7)
        try current.replace([authorization(revoked: true)])
        #expect(throws: IrxAdmissionDenied(code: .revoked)) { try judge("forged", key) }
        current.clear()
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judge(nil, key) }
        try current.replace([authorization()])
        try current.replace([authorization(key: otherKey, generation: 8)])
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judge(nil, key) }
        #expect(try judge(nil, otherKey).identityGeneration == 8)
        try current.replace([])
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judge(nil, otherKey) }
    }
}
