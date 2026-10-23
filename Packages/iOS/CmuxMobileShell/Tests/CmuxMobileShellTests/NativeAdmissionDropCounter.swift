/// Drops exactly the first remembered-auth connection, not the initial pairing.
actor NativeAdmissionDropCounter {
    private(set) var count = 0
    func shouldDrop() -> Bool { count += 1; return count == 2 }
}
