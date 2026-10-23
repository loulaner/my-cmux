#if DEBUG
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

/// Fixed diagnostic categories only; associated server messages and credentials never enter logs.
struct MobileLocalDirectFailureDiagnostic {
    let kind: String

    init(_ error: any Error) {
        if error is CancellationError { kind = "cancelled"; return }
        if let error = error as? CmxLocalDirectConnector.Failure { kind = Self.connector(error) }
        else if let error = error as? CmxLocalDirectAdmission.Failure { kind = Self.admission(error) }
        else if let error = error as? MobileShellConnectionError { kind = Self.rpc(error) }
        else { kind = "other" }
    }

    private static func connector(_ error: CmxLocalDirectConnector.Failure) -> String {
        switch error {
            case .invalidDestination: return "invalid_destination"
            case .vpnUnavailable: return "vpn_unavailable"
            case .connectionFailed: return "tcp_failed"
        }
    }

    private static func admission(_ error: CmxLocalDirectAdmission.Failure) -> String {
        switch error {
            case .denied: return "admission_denied"
            case .connectionLost: return "admission_connection_lost"
            case .timedOut: return "admission_timeout"
            case .invalidResponse: return "admission_invalid_response"
        }
    }

    private static func rpc(_ error: MobileShellConnectionError) -> String {
        switch error {
        case .connectionClosed: return "connection_closed"
        case .requestTimedOut: return "request_timeout"
        case .transportWriteTimedOut: return "write_timeout"
        case .invalidResponse: return "invalid_response"
        case .rpcError("detached", _): return "rpc_detached"
        case .rpcError("viewport_transition", _): return "rpc_viewport_transition"
        case .rpcError: return "rpc_other"
        default: return "rpc_client_other"
        }
    }
}
#endif
