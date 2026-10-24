import CmuxCloud

/// Opens pricing from the sidebar footer's Upgrade badge.
@MainActor
struct ProBadgeActions {
    static let source = ProUpgradeSource.sidebarBadge

    var openPricing: @MainActor (ProUpgradeSource) -> Void = { ProUpgradePresenter.presentAppPricingWeb(source: $0) }

    /// Opens pricing with the badge source.
    func upgrade() {
        ProUpgradePresenter.present(source: Self.source, open: openPricing)
    }


}
