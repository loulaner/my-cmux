public import CMUXMobileCore
public import CmuxMobileRPC
public import Foundation
import CmuxMobileTransport

/// An admitted session and its capability, held only until its validated record is saved.
public struct MobileLocalDirectClientConnection: Sendable {
    /// RPC session over the admitted transport.
    public let rpc: any MobileSyncing
    /// Approved device identifier.
    public let deviceID: String
    /// Capability bytes, issued now or supplied by the saved record.
    public let token: Data
    /// Creates an already admitted connection; also supports isolated business tests.
    public init(rpc: any MobileSyncing, deviceID: String, token: Data) {
        self.rpc = rpc; self.deviceID = deviceID; self.token = token
    }
    /// Pairs only for an explicit new-pair action; remembered records authenticate without fallback.
    public static func admit(transport: any CmxByteTransport, record: MobileLocalDirectClientRecord?) async throws -> Self {
        do {
            let accepted: CmxLocalDirectAdmission.ClientAccepted
            if let record {
                accepted = try await CmxLocalDirectAdmission.authenticate(deviceID: record.deviceID, token: record.token, transport: transport)
            } else {
                accepted = try await CmxLocalDirectAdmission.pair(displayName: "iPad", transport: transport)
            }
            guard let token = accepted.issuedToken ?? record?.token else { throw CmxLocalDirectAdmission.Failure.denied }
            return Self(rpc: MobileLocalDirectRPCClient(admittedTransport: accepted.transport), deviceID: accepted.deviceID, token: token)
        } catch {
            await transport.close()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
