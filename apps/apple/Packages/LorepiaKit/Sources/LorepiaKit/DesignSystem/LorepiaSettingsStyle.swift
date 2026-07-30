import SwiftUI

/// The settings surface: cards on the reading canvas rather than the system's
/// inset-grouped form.
///
/// Proportions follow the reference app, converted from its 1.585 px/pt
/// screenshot: a card inset 13pt from each edge, 30pt icon tiles, and rows
/// tall enough for a title with a line of explanation under it.
public enum LorepiaSettingsMetrics {
    public static let cardInset: CGFloat = 16
    public static let cardRadius: CGFloat = 20
    public static let cardSpacing: CGFloat = 18
    public static let rowSpacing: CGFloat = 14
    public static let tileSize: CGFloat = 30
    /// Measured against the tab bar's icons. Matching their height was not
    /// enough: those are filled shapes covering ~74% of their box while these
    /// are outlines covering ~40%, so they also need the extra size and the
    /// full-strength colour to carry the same weight.
    public static let tileGlyph: CGFloat = 24
    public static let tileTextSpacing: CGFloat = 13
}

/// One rounded card holding a group of settings.
public struct LorepiaSettingsCard<Content: View>: View {
    private let title: String?
    private let content: Content

    public init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LorepiaSettingsMetrics.rowSpacing) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LorepiaSettingsMetrics.cardInset)
        .background(
            LorepiaColor.paperRaised,
            in: RoundedRectangle(
                cornerRadius: LorepiaSettingsMetrics.cardRadius,
                style: .continuous
            )
        )
    }
}

/// The glyph that opens a settings row.
///
/// Bare rather than boxed in a coloured square: a row's colour said nothing
/// the title did not, and six tints on one page competed with the accents
/// that do carry meaning.
public struct LorepiaSettingsTile: View {
    private let glyph: LorepiaGlyph

    public init(_ glyph: LorepiaGlyph) {
        self.glyph = glyph
    }

    public var body: some View {
        LorepiaGlyphView(glyph, size: LorepiaSettingsMetrics.tileGlyph)
            .foregroundStyle(.primary)
            .frame(
                width: LorepiaSettingsMetrics.tileSize,
                height: LorepiaSettingsMetrics.tileSize
            )
            .accessibilityHidden(true)
    }
}

/// A row of the reference shape: tile, then a title with its explanation
/// underneath, then whatever the row is controlled by.
public struct LorepiaSettingsRow<Accessory: View>: View {
    private let glyph: LorepiaGlyph
    private let title: String
    private let subtitle: String?
    private let accessory: Accessory

    public init(
        glyph: LorepiaGlyph,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.glyph = glyph
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: LorepiaSettingsMetrics.tileTextSpacing) {
            LorepiaSettingsTile(glyph)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: LorepiaSpacing.compact)

            accessory
        }
        .frame(minHeight: 44)
    }
}

public extension LorepiaSettingsRow where Accessory == EmptyView {
    init(
        glyph: LorepiaGlyph,
        title: String,
        subtitle: String? = nil
    ) {
        self.init(
            glyph: glyph,
            title: title,
            subtitle: subtitle
        ) {
            EmptyView()
        }
    }
}

/// A text field inside a card, where the system form would otherwise have
/// supplied the separator that told the reader it was editable.
public struct LorepiaSettingsField: View {
    private let title: String
    private let text: Binding<String>
    private let isSecure: Bool

    public init(
        _ title: String,
        text: Binding<String>,
        isSecure: Bool = false
    ) {
        self.title = title
        self.text = text
        self.isSecure = isSecure
    }

    public var body: some View {
        Group {
            if isSecure {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, LorepiaSpacing.snug)
        .frame(minHeight: 44)
        .background(
            LorepiaColor.paper,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
