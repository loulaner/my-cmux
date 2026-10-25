import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Titles used by the remaining explicit upgrade execution layer.
@MainActor
struct AccountUpgradeOfferTests {
    @Test func menuTitlesNameTheOfferedTier() {
        #expect(ProUpgradePresenter.upgradeMenuTitle(for: .pro) == String(
            localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"
        ))
        #expect(ProUpgradePresenter.upgradeMenuTitle(for: .max) == String(
            localized: "menu.help.upgradeToMax", defaultValue: "Upgrade to cmux Max…"
        ))
    }
}
