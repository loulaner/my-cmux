#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

@Suite @MainActor
struct TerminalToolbarPresentationTests {
    @Test func fixedPolicyDoesNotIncludeLaunchersOrConfiguration() {
        let policy = TerminalToolbarPresentation.terminalOnly
        #expect(policy.fixedActions == [.control, .alternate, .command, .shift, .tab, .escape, .returnKey,
                                       .upArrow, .downArrow, .leftArrow, .rightArrow, .ctrlC, .ctrlD, .ctrlZ, .ctrlL,
                                       .home, .end, .pageUp, .pageDown, .paste, .zoomOut, .zoomIn])
        for action in [TerminalInputAccessoryAction.composer, .files, .claude, .codex, .ollama] {
            #expect(!policy.allows(action))
            #expect(TerminalToolbarPresentation.standard.allows(action))
        }
        #expect(TerminalToolbarPresentation.standard.fixedActions == nil)
    }

    @Test(arguments: [390.0, 820.0]) func actualToolbarHasOnlyTerminalControlsAndNoPinnedGap(width: Double) throws {
        let input = TerminalInputTextView(toolbarPresentation: .terminalOnly)
        let toolbar = input.toolbarView
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: 70)
        toolbar.layoutIfNeeded()
        let descendants = Self.descendants(toolbar)
        let identifiers = Set(descendants.compactMap(\.accessibilityIdentifier))
        for action in try #require(TerminalToolbarPresentation.terminalOnly.fixedActions) {
            #expect(identifiers.contains(action.accessibilityIdentifier))
        }
        for action in [TerminalInputAccessoryAction.composer, .files, .claude, .codex, .ollama] {
            #expect(!identifiers.contains(action.accessibilityIdentifier))
        }
        #expect(!identifiers.contains("terminal.inputAccessory.customize"))
        #expect(!identifiers.contains(where: { $0.hasPrefix("terminal.inputAccessory.custom.") }))
        #expect(identifiers.contains("terminal.inputAccessory.hideChrome"))
        #expect(identifiers.contains("terminal.inputAccessory.hideKeyboard"))
        let nub = try #require(descendants.first { $0 is TerminalArrowNubView })
        let scroll = try #require(descendants.first { $0 is UIScrollView })
        #expect(abs(scroll.frame.minX - nub.frame.maxX - 6) < 0.5)
        #expect(!scroll.frame.intersects(nub.frame))
        NotificationCenter.default.post(name: TerminalAccessoryConfiguration.didChangeNotification, object: nil)
        #expect(Self.descendants(toolbar).map(ObjectIdentifier.init) == descendants.map(ObjectIdentifier.init))
    }

    @Test func rejectedHandlersDoNotEmitInputAndStandardKeepsComposer() {
        let input = TerminalInputTextView(toolbarPresentation: .terminalOnly)
        var bytes: [Data] = []
        var composerCalls = 0
        input.onEscapeSequence = { bytes.append($0) }
        input.onToggleComposer = { composerCalls += 1 }
        for action in [TerminalInputAccessoryAction.composer, .files, .claude, .codex, .ollama] {
            input.simulateAccessoryActionForTesting(action)
        }
        #expect(bytes.isEmpty)
        #expect(composerCalls == 0)
        input.simulateAccessoryActionForTesting(.ctrlC)
        #expect(bytes == [Data([3])])
        let standard = TerminalInputTextView()
        standard.onToggleComposer = { composerCalls += 1 }
        standard.simulateAccessoryActionForTesting(.composer)
        #expect(composerCalls == 1)
        let identifiers = Self.descendants(standard.toolbarView).compactMap(\.accessibilityIdentifier)
        #expect(identifiers.contains(TerminalInputAccessoryAction.composer.accessibilityIdentifier))
        #expect(identifiers.contains("terminal.inputAccessory.customize"))
    }

    @Test func pasteUsesOnlyPlainTextEvenWhenImageIsPresent() throws {
        let input = TerminalInputTextView(toolbarPresentation: .terminalOnly)
        let pasteboard = UIPasteboard.general
        let original = pasteboard.items
        defer { pasteboard.items = original }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let png = try #require(image.pngData())
        let text = "中文\u{03}"
        var received: [String] = []
        var images = 0
        input.onText = { received.append($0) }
        input.onPasteImage = { _, _ in images += 1 }
        pasteboard.items = [["public.png": png, "public.utf8-plain-text": text]]
        input.paste(nil)
        #expect(received == [text])
        #expect(images == 0)
        pasteboard.items = [["public.png": png]]
        input.simulateAccessoryActionForTesting(.paste)
        #expect(received == [text])
        #expect(images == 0)
    }

    private static func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
#endif
