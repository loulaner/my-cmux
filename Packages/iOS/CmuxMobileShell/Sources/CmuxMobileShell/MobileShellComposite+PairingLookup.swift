internal import CmuxMobilePairedMac

extension MobileShellComposite {
    func taskComposerTargetName(macDeviceID: String, instanceTag: String?) -> String {
        displayPairedMacs.first {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        }?.resolvedName
            ?? pairedMacs.first {
                MacPairingKey($0) == MacPairingKey(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            }?.resolvedName
            ?? macDeviceID
    }

    /// Whether the foreground connection already targets this exact Mac pairing.
    /// A missing tag matches only another untagged legacy pairing.
    func matchesForegroundPairing(macDeviceID: String, instanceTag: String?) -> Bool {
        guard let foregroundMacDeviceID else { return false }
        return MacPairingKey(
            macDeviceID: foregroundMacDeviceID,
            instanceTag: activeMacInstanceTag
        ) == MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }

    /// Resolves a secondary control subscription for one exact pairing.
    /// A missing tag names only a legacy untagged row. It never selects an
    /// arbitrary Stable/Nightly sibling on the same physical Mac.
    func controlSubscriptionMatching(
        macDeviceID: String,
        instanceTag: String?
    ) -> SecondaryMacSubscription? {
        let probe = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        return secondaryMacSubscriptions[probe]
    }
}
