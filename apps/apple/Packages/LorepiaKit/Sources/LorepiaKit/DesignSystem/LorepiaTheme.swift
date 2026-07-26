import SwiftUI

public enum LorepiaSpacing {
    public static let compact: CGFloat = 8
    public static let standard: CGFloat = 16
    public static let roomy: CGFloat = 24
}

public struct LorepiaCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public func body(content: Content) -> some View {
        content
            .padding(LorepiaSpacing.standard)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(0.07)
                    : Color.black.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

public extension View {
    func lorepiaCard() -> some View {
        modifier(LorepiaCardModifier())
    }
}
