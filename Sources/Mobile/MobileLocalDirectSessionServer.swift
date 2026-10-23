import CMUXMobileCore
import CmuxMobileTransport
import Foundation

/// Owns one route-gated TCP admission and its existing-terminal control RPC session.
struct MobileLocalDirectSessionServer: Sendable {
    let hostDeviceID: String
    let store: CmxLocalDeviceCredentialStore
    let approval: @Sendable (String) async -> Bool
    let isCurrent: @Sendable () async -> Bool
    let managedPolicyDisabled: @Sendable () -> Bool
    let onAdmitted: @Sendable () async -> Void
    let registry: MobileHostConnectionRegistry

    init(hostDeviceID: String, store: CmxLocalDeviceCredentialStore,
         approval: @escaping @Sendable (String) async -> Bool,
         isCurrent: @escaping @Sendable () async -> Bool,
         managedPolicyDisabled: @escaping @Sendable () -> Bool = { MobileRemoteControlPolicy.isDisabled },
         registry: MobileHostConnectionRegistry = .shared,
         onAdmitted: @escaping @Sendable () async -> Void = {}) {
        self.hostDeviceID = hostDeviceID
        self.store = store
        self.approval = approval
        self.isCurrent = isCurrent
        self.managedPolicyDisabled = managedPolicyDisabled
        self.registry = registry
        self.onAdmitted = onAdmitted
    }

    /// Only the VPN-gated listener supplies product transports; this owner never starts listening.
    func serve(_ transport: any CmxByteTransport) async {
        guard !hostDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await transport.close(); return
        }
        let current: @Sendable () async -> Bool = {
            guard !managedPolicyDisabled() else { return false }
            return await isCurrent()
        }
        do {
            let accepted = try await CmxLocalDirectAdmission(store: store, approval: approval, isCurrent: current).accept(transport)
            guard await current(), await accepted.isAuthorized(), !Task.isCancelled else {
                await transport.close(); return
            }
            await onAdmitted()
            _ = await MobileHostService.acceptTransport(
                accepted.transport, authorization: .localDirect(accepted.peer), registry: registry,
                hostDeviceID: hostDeviceID, localDirectIsAuthorized: accepted.isAuthorized,
                remoteControlDisabledByPolicy: managedPolicyDisabled, isCurrent: current)
        } catch { /* Admission exposes only its fixed denied response and closes. */ }
        await transport.close()
    }
}
