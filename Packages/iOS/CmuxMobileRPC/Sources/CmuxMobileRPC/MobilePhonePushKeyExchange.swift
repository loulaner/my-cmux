public import CMUXMobileCore
import Foundation

/// Values needed by Hooke's existing key/pin store after the authenticated RPC.
public struct MobilePhonePushKeyExchangeContext: Sendable {
    public let accountID: String
    public let teamID: String?
    public let clientID: String
    public let iosBuildID: String
    public let iosInstallationID: String
    public let macDeviceID: String
    public let macInstanceTag: String
    public let macBuildID: String

    public init(
        accountID: String,
        teamID: String?,
        clientID: String,
        iosBuildID: String,
        iosInstallationID: String,
        macDeviceID: String,
        macInstanceTag: String,
        macBuildID: String
    ) {
        self.accountID = accountID
        self.teamID = teamID
        self.clientID = clientID
        self.iosBuildID = iosBuildID
        self.iosInstallationID = iosInstallationID
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macBuildID = macBuildID
    }
}

/// Shell-to-push injection boundary. Hooke supplies the descriptor and pins
/// the returned Mac descriptor in the shared PhonePushPeerKeyStore.
public struct MobilePhonePushKeyExchangeHooks: Sendable {
    public let makeDescriptor: @Sendable () throws -> MobilePhonePushPublicKeyDescriptor
    public let iosBuildID: @Sendable () -> String
    public let pinPeerDescriptor: @MainActor @Sendable (
        MobilePhonePushPublicKeyDescriptor,
        MobilePhonePushKeyExchangeContext
    ) async -> Void

    public init(
        makeDescriptor: @escaping @Sendable () throws -> MobilePhonePushPublicKeyDescriptor,
        iosBuildID: @escaping @Sendable () -> String,
        pinPeerDescriptor: @escaping @MainActor @Sendable (
            MobilePhonePushPublicKeyDescriptor,
            MobilePhonePushKeyExchangeContext
        ) async -> Void
    ) {
        self.makeDescriptor = makeDescriptor
        self.iosBuildID = iosBuildID
        self.pinPeerDescriptor = pinPeerDescriptor
    }
}
