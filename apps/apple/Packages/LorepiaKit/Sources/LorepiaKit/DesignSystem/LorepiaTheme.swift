import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum LorepiaSpacing {
    public static let tight: CGFloat = 4
    public static let compact: CGFloat = 8
    public static let snug: CGFloat = 12
    public static let standard: CGFloat = 16
    public static let roomy: CGFloat = 24
    public static let generous: CGFloat = 32
}

public enum LorepiaRadius {
    public static let card: CGFloat = 12
    public static let bubble: CGFloat = 19
    public static let field: CGFloat = 22
}

/// Content-layer colors for LorePia.
///
/// These describe the reading surface only: the page, message fills, and the
/// two accents that carry meaning (branching and generation). Navigation
/// chrome — toolbars, tab bars, and the composer surface — deliberately keeps
/// the system material so it stays consistent with the platform.
public enum LorepiaColor {
    /// The reading canvas. Warm rather than pure white for long sessions.
    public static let paper = adaptive(
        light: 0xF7F3EC,
        dark: 0x121116,
        lightIncreasedContrast: 0xFFFDF8,
        darkIncreasedContrast: 0x08080B
    )

    /// Raised content sitting on `paper`, such as cards.
    public static let paperRaised = adaptive(
        light: 0xFFFFFF,
        dark: 0x1C1B21,
        lightIncreasedContrast: 0xFFFFFF,
        darkIncreasedContrast: 0x22212A
    )

    /// Fill for incoming messages. Borderless, like the platform's own bubbles.
    public static let incomingFill = adaptive(
        light: 0xEFE9DE,
        dark: 0x26242B,
        lightIncreasedContrast: 0xE1D8C6,
        darkIncreasedContrast: 0x36333D
    )

    /// Fill for outgoing messages and primary controls. Pairs with white text.
    public static let loreFill = adaptive(
        light: 0x4A3FB5,
        dark: 0x5B4FD6,
        lightIncreasedContrast: 0x2F2380,
        darkIncreasedContrast: 0x4234B9
    )

    /// The same brand hue, legible as text or a symbol on `paper`.
    public static let loreAccent = adaptive(
        light: 0x4A3FB5,
        dark: 0xB0A3F7,
        lightIncreasedContrast: 0x2F2380,
        darkIncreasedContrast: 0xCFC6FF
    )

    /// Reserved for branching. Nothing else uses this hue.
    public static let thread = adaptive(
        light: 0x0F6E56,
        dark: 0x6FD6C4,
        lightIncreasedContrast: 0x06452F,
        darkIncreasedContrast: 0x9DEBDB
    )

    /// Tinted background behind branch affordances.
    public static let threadSoft = adaptive(
        light: 0xE1F5EE,
        dark: 0x12332B,
        lightIncreasedContrast: 0xCDEEE1,
        darkIncreasedContrast: 0x18443A
    )

    /// The rail drawn beside the timeline where a conversation can fork.
    public static let threadRail = adaptive(
        light: 0xC7DBD1,
        dark: 0x354942,
        lightIncreasedContrast: 0xA6C4B7,
        darkIncreasedContrast: 0x4A635A
    )

    /// Reserved for generation in progress and for stopping it.
    public static let ember = adaptive(
        light: 0xC4562E,
        dark: 0xF0906F,
        lightIncreasedContrast: 0x8E3717,
        darkIncreasedContrast: 0xFFB69B
    )
}

public struct LorepiaCardModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(LorepiaSpacing.standard)
            .background(
                LorepiaColor.paperRaised,
                in: RoundedRectangle(
                    cornerRadius: LorepiaRadius.card,
                    style: .continuous
                )
            )
    }
}

public extension View {
    func lorepiaCard() -> some View {
        modifier(LorepiaCardModifier())
    }

    /// Replaces a scrollable view's system background with the reading canvas.
    ///
    /// Navigation chrome keeps its own material, so the canvas stops at the
    /// content layer and lets the system draw scroll edge effects over it.
    @ViewBuilder
    func lorepiaCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(LorepiaColor.paper)
    }
}

extension LorepiaColor {
    static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightIncreasedContrast: UInt32,
        darkIncreasedContrast: UInt32
    ) -> Color {
#if canImport(UIKit)
        Color(
            uiColor: UIColor { traits in
                let increased = traits.accessibilityContrast == .high
                switch traits.userInterfaceStyle {
                case .dark:
                    return UIColor(
                        hex: increased ? darkIncreasedContrast : dark
                    )
                default:
                    return UIColor(
                        hex: increased ? lightIncreasedContrast : light
                    )
                }
            }
        )
#elseif canImport(AppKit)
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let increased = NSWorkspace.shared
                    .accessibilityDisplayShouldIncreaseContrast
                let isDark = appearance.bestMatch(
                    from: [.aqua, .darkAqua]
                ) == .darkAqua
                if isDark {
                    return NSColor(
                        hex: increased ? darkIncreasedContrast : dark
                    )
                }
                return NSColor(
                    hex: increased ? lightIncreasedContrast : light
                )
            }
        )
#else
        Color(
            red: Double((light >> 16) & 0xFF) / 255,
            green: Double((light >> 8) & 0xFF) / 255,
            blue: Double(light & 0xFF) / 255
        )
#endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
