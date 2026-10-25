import CmuxCloud
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct MobileFileTransferPolicyTests {
    @Test func disabledPolicyReturnsSharedRefusal() {
        guard case let .err(code, message, data)? = TerminalController.mobileFileTransferPolicyError(isDisabled: true) else {
            Issue.record("Disabled file transfer must return a refusal")
            return
        }
        #expect(code == "file_transfer_disabled")
        #expect(message == ManagedFileTransferPolicy.disabledMessage)
        #expect(data == nil)
    }

    @Test func enabledPolicyDoesNotRefuse() {
        #expect(TerminalController.mobileFileTransferPolicyError(isDisabled: false) == nil)
    }

    @Test func alternatingDecisionsDoNotRetainState() {
        for disabled in [true, false, true, false] {
            let result = TerminalController.mobileFileTransferPolicyError(isDisabled: disabled)
            if disabled {
                guard case let .err(code, message, data)? = result else {
                    Issue.record("Each disabled decision must return a refusal")
                    continue
                }
                #expect(code == "file_transfer_disabled")
                #expect(message == ManagedFileTransferPolicy.disabledMessage)
                #expect(data == nil)
            } else {
                #expect(result == nil)
            }
        }
    }
}
