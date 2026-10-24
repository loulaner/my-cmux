import CmuxMobileSupport
import SwiftUI

/// An informational surface; it never starts authentication or offers an action.
@available(iOS 17.0, macOS 14.0, *)
struct MobileAccountSignInUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label(
                L10n.string(
                    "mobile.signIn.unavailable.title",
                    defaultValue: "Account sign-in is unavailable"
                ),
                systemImage: "person.crop.circle.badge.xmark"
            )
        } description: {
            Text(L10n.string(
                "mobile.signIn.unavailable.message",
                defaultValue: "This version does not support account sign-in."
            ))
        }
    }
}
