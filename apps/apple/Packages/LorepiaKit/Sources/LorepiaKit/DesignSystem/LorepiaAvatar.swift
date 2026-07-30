import SwiftUI

/// A character avatar for the common case: no artwork.
///
/// With a name it shows that name's first letter, which reads as a portrait
/// standing in for someone rather than as a missing-image icon. It stays
/// neutral: colour in this app carries meaning elsewhere, and a per-character
/// hue here competed with it for no information gained.
public struct LorepiaAvatar: View {
    private let symbolName: String
    private let name: String?
    private let size: CGFloat

    @Environment(\.locale) private var locale

    public init(
        symbolName: String,
        size: CGFloat,
        name: String? = nil
    ) {
        self.symbolName = symbolName
        self.size = size
        self.name = name
    }

    public var body: some View {
        ZStack {
            // One flat tint, as the system does minus its gradient: nothing
            // about a stand-in portrait needs shading.
            Circle().fill(LorepiaColor.avatarFill)

            if let monogram {
                Text(monogram)
                    .font(
                        .system(
                            size: size * 0.42,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, size * 0.12)
            } else {
                // Placed like the system's own: the head lands on the disc's
                // centre and the shoulders run past the bottom edge, where the
                // circle crops them. The numbers come from measuring the
                // rendered symbol — its ink is about 0.83 of the point size,
                // centred in the font box.
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.96, weight: .regular))
                    .offset(y: size * 0.204)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// The first letter of the name, if there is a name with a letter in it.
    private var monogram: String? {
        guard
            let trimmed = name?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            let first = trimmed.first(where: {
                $0.isLetter || $0.isNumber
            })
        else {
            return nil
        }
        return String(first).uppercased(with: locale)
    }
}
