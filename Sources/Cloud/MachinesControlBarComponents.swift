import CmuxAppKitSupportUI
import CmuxCloud
import AppKit
import SwiftUI

/// A read-only free-access deadline warning with an independent dismiss button.
struct MachinesFreeAccessBanner: View {
    let text: String
    let isExpired: Bool
    let backgroundColor: NSColor
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: isExpired ? "lock.fill" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .cmuxFont(size: 11, monospacedDigit: true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .foregroundColor(isExpired ? Color.orange : .secondary)
            .accessibilityLabel(text)
            .layoutPriority(1)
            CloudBannerDismissButton(action: onDismiss)
        }
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(isExpired ? Color.orange : .secondary)
        .contentShape(Rectangle())
        .background(Color(nsColor: backgroundColor))
        .help(text)
        .accessibilityIdentifier("CloudMachinesFreeAccessBanner")
    }
}

struct MachinesChromeIconButton: View {
    let symbolName: String
    let accessibilityLabel: String
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    // The glyph draws into the whole button canvas, centered
                    // by its visible pixels. Centering its layout box instead
                    // leaves glyphs like `trash` a point low.
                    CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                        source: symbolSource,
                        size: NSSize(width: 22, height: 20),
                        tintColor: isHovered ? .labelColor : .secondaryLabelColor,
                        symbolWeight: .medium,
                        fallbackSource: symbolSource,
                        symbolPointSize: 11,
                        centersVisibleContent: true
                    ))
                    .accessibilityHidden(true)
                }
            }
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovered ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolSource: CmuxResolvedIconSource {
        .systemSymbol(name: symbolName, accessibilityDescription: nil)
    }
}

/// A short labeled chrome button for the one action the header must sell
/// (Invite). Same height and tint rules as ``MachinesChromeIconButton``.
struct MachinesChromeLabelButton: View {
    let symbolName: String
    let title: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .cmuxFont(size: 11, weight: .medium)
            }
            // Same grey and hover rule as the tab bar's mode labels above.
            .foregroundColor(RightSidebarChromeControlStyle.pillForegroundColor(isSelected: false, isHovered: isHovered))
            .padding(.leading, 7)
            // The text ends under the tab bar's close glyph (12 pt from the edge).
            .padding(.trailing, 4)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .safeHelp(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
