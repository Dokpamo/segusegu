import SwiftUI

/// The icon family LorePia draws itself.
///
/// Every glyph is built on one 24-unit grid with a single stroke weight, round
/// caps, and round joins, so the message actions read as one set instead of a
/// mix of borrowed symbols. Shapes stay abstract: a container, a split, a turn.
public enum LorepiaGlyph: String, CaseIterable, Sendable {
    case edit
    case copy
    case regenerate
    case branch
    case delete
    case check

    static let grid: CGFloat = 24
    static let stroke: CGFloat = 1.8

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.grid
        var path = Path()
        draw(into: &path)
        return path.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(
                    CGAffineTransform(
                        translationX: rect.minX
                            + (rect.width - Self.grid * scale) / 2,
                        y: rect.minY
                            + (rect.height - Self.grid * scale) / 2
                    )
                )
        )
    }

    private func draw(into path: inout Path) {
        switch self {
        case .edit:
            // An open container with a stroke leaving through the gap.
            path.move(to: CGPoint(x: 14, y: 4))
            path.addArc(
                tangent1End: CGPoint(x: 4, y: 4),
                tangent2End: CGPoint(x: 4, y: 14),
                radius: 4.5
            )
            path.addArc(
                tangent1End: CGPoint(x: 4, y: 20),
                tangent2End: CGPoint(x: 14, y: 20),
                radius: 4.5
            )
            path.addArc(
                tangent1End: CGPoint(x: 20, y: 20),
                tangent2End: CGPoint(x: 20, y: 13),
                radius: 4.5
            )
            path.move(to: CGPoint(x: 10.5, y: 13.5))
            path.addLine(to: CGPoint(x: 19.5, y: 4.5))

        case .copy:
            // Two soft plates, one lifted off the other. The back plate is
            // drawn only where the front one does not cover it.
            path.addRoundedRect(
                in: CGRect(x: 3.5, y: 7.5, width: 13, height: 13),
                cornerSize: CGSize(width: 4.5, height: 4.5)
            )
            path.move(to: CGPoint(x: 8.5, y: 3.5))
            path.addLine(to: CGPoint(x: 16, y: 3.5))
            path.addQuadCurve(
                to: CGPoint(x: 20.5, y: 8),
                control: CGPoint(x: 20.5, y: 3.5)
            )
            path.addLine(to: CGPoint(x: 20.5, y: 12))
            path.addQuadCurve(
                to: CGPoint(x: 16, y: 16.5),
                control: CGPoint(x: 20.5, y: 16.5)
            )

        case .regenerate:
            // A turn that comes back around, with the opening at the top right
            // and the tip resting on it.
            path.addArc(
                center: CGPoint(x: 12, y: 12),
                radius: 7.6,
                startAngle: .degrees(-38),
                endAngle: .degrees(232),
                clockwise: false
            )
            path.move(to: CGPoint(x: 15.4, y: 3.6))
            path.addLine(to: CGPoint(x: 19.6, y: 7.2))
            path.addLine(to: CGPoint(x: 14.4, y: 8.6))
            path.closeSubpath()

        case .branch:
            // A thread running on, and one leaving it for somewhere else.
            path.move(to: CGPoint(x: 7.5, y: 3.5))
            path.addLine(to: CGPoint(x: 7.5, y: 20.5))
            path.move(to: CGPoint(x: 7.5, y: 14))
            path.addCurve(
                to: CGPoint(x: 16.5, y: 7),
                control1: CGPoint(x: 7.5, y: 9.5),
                control2: CGPoint(x: 12.5, y: 10.5)
            )
            path.addEllipse(
                in: CGRect(x: 14.3, y: 4.8, width: 4.4, height: 4.4)
            )

        case .delete:
            // A tapered vessel under a lifted lid. No handle, no tick marks.
            path.move(to: CGPoint(x: 4.5, y: 7))
            path.addLine(to: CGPoint(x: 19.5, y: 7))
            path.move(to: CGPoint(x: 6.6, y: 7))
            path.addLine(to: CGPoint(x: 7.8, y: 18.6))
            path.addQuadCurve(
                to: CGPoint(x: 9.6, y: 20.6),
                control: CGPoint(x: 8, y: 20.6)
            )
            path.addLine(to: CGPoint(x: 14.4, y: 20.6))
            path.addQuadCurve(
                to: CGPoint(x: 16.2, y: 18.6),
                control: CGPoint(x: 16, y: 20.6)
            )
            path.addLine(to: CGPoint(x: 17.4, y: 7))

        case .check:
            path.move(to: CGPoint(x: 5, y: 12.5))
            path.addLine(to: CGPoint(x: 10, y: 17.5))
            path.addLine(to: CGPoint(x: 19, y: 6.5))
        }
    }
}

/// Renders a `LorepiaGlyph` at a size that follows Dynamic Type.
public struct LorepiaGlyphView: View {
    private let glyph: LorepiaGlyph
    private let size: CGFloat

    public init(_ glyph: LorepiaGlyph, size: CGFloat) {
        self.glyph = glyph
        self.size = size
    }

    public var body: some View {
        LorepiaGlyphShape(glyph: glyph)
            .stroke(
                style: StrokeStyle(
                    lineWidth: LorepiaGlyph.stroke * (size / LorepiaGlyph.grid),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
    }
}

private struct LorepiaGlyphShape: Shape {
    let glyph: LorepiaGlyph

    func path(in rect: CGRect) -> Path {
        glyph.path(in: rect)
    }
}
