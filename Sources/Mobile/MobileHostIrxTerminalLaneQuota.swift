/// Tracks active IRX terminal lanes rather than cumulative opens. Replay
/// barriers intentionally close and reopen lanes, so a connection must return
/// its credit when a serving task finishes or the fast input lane eventually
/// becomes permanently unavailable after four reopen cycles.
actor MobileHostIrxTerminalLaneQuota {
    private static let maximum = 4
    private var activeCount = 0

    func reserve() -> Bool {
        guard activeCount < Self.maximum else { return false }
        activeCount += 1
        return true
    }

    func release() {
        activeCount = max(0, activeCount - 1)
    }
}
