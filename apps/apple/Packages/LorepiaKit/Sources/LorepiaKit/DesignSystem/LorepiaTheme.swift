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
/// accent colors that carry product meaning. Navigation
/// chrome — toolbars, tab bars, and the composer surface — deliberately keeps
/// the system material so it stays consistent with the platform.
public enum LorepiaColor {
    /// The reading canvas. Warm rather than pure white for long sessions —
    /// and warm in the dark too, where a blue-leaning charcoal would drop the
    /// paper identity the moment the lights go out.
    public static let paper = adaptive(
        light: 0xF7F3EC,
        dark: 0x17150F,
        lightIncreasedContrast: 0xFFFDF8,
        darkIncreasedContrast: 0x0B0A07
    )

    /// Raised content sitting on `paper`, such as cards.
    public static let paperRaised = adaptive(
        light: 0xFFFFFF,
        dark: 0x211E17,
        lightIncreasedContrast: 0xFFFFFF,
        darkIncreasedContrast: 0x28241C
    )

    /// Fill for incoming messages. Borderless, like the platform's own bubbles.
    public static let incomingFill = adaptive(
        light: 0xEFE9DE,
        dark: 0x2B2721,
        lightIncreasedContrast: 0xE1D8C6,
        darkIncreasedContrast: 0x3A352C
    )

    /// Fill for outgoing messages and primary controls. Pairs with white text.
    public static let loreFill = adaptive(
        light: 0x4A3FB5,
        dark: 0x5B4FD6,
        lightIncreasedContrast: 0x2F2380,
        darkIncreasedContrast: 0x4234B9
    )

    /// Fill for outgoing messages.
    ///
    /// Grey rather than a hue: the reader wrote these and only needs to find
    /// them again, which the trailing edge already does. Keeping colour out
    /// of them leaves the reply the only tinted surface worth reading.
    public static let outgoingFill = adaptive(
        light: 0xDFDDD8,
        dark: 0x343029,
        lightIncreasedContrast: 0xCBC8C2,
        darkIncreasedContrast: 0x444037
    )

    /// The same brand hue, legible as text or a symbol on `paper`.
    public static let loreAccent = adaptive(
        light: 0x4A3FB5,
        dark: 0xB0A3F7,
        lightIncreasedContrast: 0x2F2380,
        darkIncreasedContrast: 0xCFC6FF
    )

    /// Reserved for generation in progress and for stopping it.
    public static let ember = adaptive(
        light: 0xC4562E,
        dark: 0xF0906F,
        lightIncreasedContrast: 0x8E3717,
        darkIncreasedContrast: 0xFFB69B
    )

    /// The avatar disc.
    ///
    /// One flat tint for everyone, as the system's placeholder avatars do: a
    /// per-character hue would compete with the colours that carry meaning.
    /// Deep enough that the letter on it can be white, like the system's.
    public static let avatarFill = adaptive(
        light: 0x847C6E,
        dark: 0x423D35,
        lightIncreasedContrast: 0x6C6459,
        darkIncreasedContrast: 0x544E43
    )

    /// The day marker's capsule. It is chrome, so it stays a neutral warm
    /// grey — and in the dark it steps down instead of becoming the brightest
    /// block on a page whose text it is only labelling.
    public static let dayMarker = adaptive(
        light: 0x8C8880,
        dark: 0x413C33,
        lightIncreasedContrast: 0x6C6960,
        darkIncreasedContrast: 0x565046
    )

    /// The band behind a search hit. Amber reads as "found" while staying in
    /// the paper palette's warmth, and stays clear of the generation hue
    /// that already carries meaning.
    public static let highlight = adaptive(
        light: 0xF2C14E,
        dark: 0xC08A1E,
        lightIncreasedContrast: 0xE0A521,
        darkIncreasedContrast: 0xD9A230
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
