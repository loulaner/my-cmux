import CmuxAppKitSupportUI
import CmuxCloud
import AppKit
import SwiftUI

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
