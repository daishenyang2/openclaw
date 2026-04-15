import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
extension NSAppearance {
    fileprivate var isDarkAqua: Bool {
        self.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
#endif

enum OpenClawChatTheme {
    #if os(macOS)
    static func resolvedAssistantBubbleColor(for appearance: NSAppearance) -> NSColor {
        // NSColor semantic colors don't reliably resolve for arbitrary NSAppearance in SwiftPM.
        // Use explicit light/dark values so the bubble updates when the system appearance flips.
        appearance.isDarkAqua
            ? NSColor(calibratedWhite: 0.18, alpha: 0.88)
            : NSColor(calibratedWhite: 0.94, alpha: 0.92)
    }

    static func resolvedOnboardingAssistantBubbleColor(for appearance: NSAppearance) -> NSColor {
        appearance.isDarkAqua
            ? NSColor(calibratedWhite: 0.20, alpha: 0.94)
            : NSColor(calibratedWhite: 0.97, alpha: 0.98)
    }

    static let assistantBubbleDynamicNSColor = NSColor(
        name: NSColor.Name("OpenClawChatTheme.assistantBubble"),
        dynamicProvider: resolvedAssistantBubbleColor(for:))

    static let onboardingAssistantBubbleDynamicNSColor = NSColor(
        name: NSColor.Name("OpenClawChatTheme.onboardingAssistantBubble"),
        dynamicProvider: resolvedOnboardingAssistantBubbleColor(for:))
    #endif

    static var surface: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    @ViewBuilder
    static var background: some View {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var card: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var subtleCard: AnyShapeStyle {
        #if os(macOS)
        AnyShapeStyle(.ultraThinMaterial)
        #else
        AnyShapeStyle(Color(uiColor: .secondarySystemBackground).opacity(0.9))
        #endif
    }

    #if os(macOS)
    static let userBubbleDynamicNSColor = NSColor(
        name: NSColor.Name("OpenClawChatTheme.userBubble"),
        dynamicProvider: { appearance in
            // Subtle neutral slate that pairs cleanly with labelColor text
            // in both light and dark mode without looking saturated.
            appearance.isDarkAqua
                ? NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.26, alpha: 1.0)
                : NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)
        })
    #endif

    static var userBubble: Color {
        #if os(macOS)
        Color(nsColor: self.userBubbleDynamicNSColor)
        #else
        Color(red: 0.94, green: 0.95, blue: 0.97)
        #endif
    }

    static var assistantBubble: Color {
        #if os(macOS)
        Color(nsColor: self.assistantBubbleDynamicNSColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var onboardingAssistantBubble: Color {
        #if os(macOS)
        Color(nsColor: self.onboardingAssistantBubbleDynamicNSColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var onboardingAssistantBorder: Color {
        #if os(macOS)
        Color.white.opacity(0.12)
        #else
        Color.white.opacity(0.12)
        #endif
    }

    static var userText: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color.primary
        #endif
    }

    static var assistantText: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }

    static var composerBackground: AnyShapeStyle {
        #if os(macOS)
        AnyShapeStyle(.ultraThinMaterial)
        #else
        AnyShapeStyle(Color(uiColor: .systemBackground))
        #endif
    }

    static var composerField: AnyShapeStyle {
        #if os(macOS)
        AnyShapeStyle(.thinMaterial)
        #else
        AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        #endif
    }

    static var composerBorder: Color {
        Color.white.opacity(0.12)
    }

    static var divider: Color {
        Color.secondary.opacity(0.2)
    }
}

enum OpenClawPlatformImageFactory {
    static func image(_ image: OpenClawPlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}
