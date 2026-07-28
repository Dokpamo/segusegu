import SwiftUI

/// A character avatar: the character's symbol inside a tinted, ringed circle.
///
/// Characters arrive from imported packages without artwork we can rely on, so
/// the ring color is derived from the character identifier. The same character
/// keeps the same color everywhere in the app without storing anything extra.
public struct LorepiaAvatar: View {
    private let symbolName: String
    private let seed: String
    private let size: CGFloat

    public init(
        symbolName: String,
        seed: String,
        size: CGFloat
    ) {
        self.symbolName = symbolName
        self.seed = seed
        self.size = size
    }

    public var body: some View {
        let hue = LorepiaAvatarHue.hue(for: seed)
        Image(systemName: symbolName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(hue.symbol)
            .frame(width: size, height: size)
            .background(hue.fill, in: Circle())
            .overlay {
                Circle().strokeBorder(hue.ring, lineWidth: 2)
            }
            .accessibilityHidden(true)
    }
}

enum LorepiaAvatarHue {
    struct Palette {
        let fill: Color
        let ring: Color
        let symbol: Color
    }

    static func hue(for seed: String) -> Palette {
        let index = Int(stableHash(seed) % UInt(palettes.count))
        return palettes[index]
    }

    private static let palettes: [Palette] = [
        palette(
            light: (0xEEEDFE, 0x7F77DD, 0x3C3489),
            dark: (0x241F45, 0x7F77DD, 0xCECBF6)
        ),
        palette(
            light: (0xE1F5EE, 0x5DCAA5, 0x0F6E56),
            dark: (0x123328, 0x1D9E75, 0x9FE1CB)
        ),
        palette(
            light: (0xFAECE7, 0xF0997B, 0x993C1D),
            dark: (0x3A1B10, 0xD85A30, 0xF5C4B3)
        ),
        palette(
            light: (0xFBEAF0, 0xED93B1, 0x993556),
            dark: (0x3A1524, 0xD4537E, 0xF4C0D1)
        ),
        palette(
            light: (0xFAEEDA, 0xEF9F27, 0x854F0B),
            dark: (0x3A2606, 0xBA7517, 0xFAC775)
        ),
        palette(
            light: (0xE6F1FB, 0x85B7EB, 0x185FA5),
            dark: (0x0F2740, 0x378ADD, 0xB5D4F4)
        ),
    ]

    private typealias Stops = (
        fill: UInt32,
        ring: UInt32,
        symbol: UInt32
    )

    private static func palette(
        light: Stops,
        dark: Stops
    ) -> Palette {
        Palette(
            fill: LorepiaColor.adaptive(
                light: light.fill,
                dark: dark.fill,
                lightIncreasedContrast: light.fill,
                darkIncreasedContrast: dark.fill
            ),
            ring: LorepiaColor.adaptive(
                light: light.ring,
                dark: dark.ring,
                lightIncreasedContrast: light.symbol,
                darkIncreasedContrast: dark.symbol
            ),
            symbol: LorepiaColor.adaptive(
                light: light.symbol,
                dark: dark.symbol,
                lightIncreasedContrast: light.symbol,
                darkIncreasedContrast: dark.symbol
            )
        )
    }

    /// A hash that stays stable across launches, unlike `String.hashValue`.
    private static func stableHash(_ value: String) -> UInt {
        var result: UInt = 5381
        for byte in value.utf8 {
            result = (result &* 33) &+ UInt(byte)
        }
        return result
    }
}
