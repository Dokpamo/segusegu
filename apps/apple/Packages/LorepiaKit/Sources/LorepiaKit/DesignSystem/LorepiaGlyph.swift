import SwiftUI

/// The icon family LorePia draws itself.
///
/// Every glyph is built on one 24-unit grid with round caps and joins, so the
/// message actions and composer controls read as one set instead of a mix of
/// borrowed symbols.
public enum LorepiaGlyph: String, CaseIterable, Sendable {
    case edit
    case copy
    case regenerate
    case branch
    case plus
    case send
    case moreVertical
    case delete
    case shield
    case settings
    case waveform
    case check
    case search
    case close
    case expand
    case collapse

    static let grid: CGFloat = 24

    var stroke: CGFloat {
        switch self {
        case
            .edit, .copy, .branch, .plus, .send, .moreVertical, .delete,
            .shield, .settings, .waveform, .search, .close, .expand,
            .collapse:
            2
        case .regenerate, .check:
            1.8
        }
    }

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
            path.move(to: CGPoint(x: 14, y: 4))
            path.addLine(to: CGPoint(x: 8, y: 4))
            path.addArc(
                tangent1End: CGPoint(x: 4, y: 4),
                tangent2End: CGPoint(x: 4, y: 8),
                radius: 4
            )
            path.addLine(to: CGPoint(x: 4, y: 16))
            path.addArc(
                tangent1End: CGPoint(x: 4, y: 20),
                tangent2End: CGPoint(x: 8, y: 20),
                radius: 4
            )
            path.addLine(to: CGPoint(x: 16, y: 20))
            path.addArc(
                tangent1End: CGPoint(x: 20, y: 20),
                tangent2End: CGPoint(x: 20, y: 16),
                radius: 4
            )
            path.addLine(to: CGPoint(x: 20, y: 10))
            path.move(to: CGPoint(x: 10.5, y: 13.5))
            path.addLine(to: CGPoint(x: 19.5, y: 4.5))

        case .copy:
            path.addRoundedRect(
                in: CGRect(x: 3.5, y: 8, width: 12.5, height: 12.5),
                cornerSize: CGSize(width: 4.5, height: 4.5)
            )
            path.move(to: CGPoint(x: 8, y: 8))
            path.addArc(
                tangent1End: CGPoint(x: 8, y: 3.5),
                tangent2End: CGPoint(x: 12.5, y: 3.5),
                radius: 4.5
            )
            path.addLine(to: CGPoint(x: 16, y: 3.5))
            path.addArc(
                tangent1End: CGPoint(x: 20.5, y: 3.5),
                tangent2End: CGPoint(x: 20.5, y: 8),
                radius: 4.5
            )
            path.addLine(to: CGPoint(x: 20.5, y: 11.5))
            path.addArc(
                tangent1End: CGPoint(x: 20.5, y: 16),
                tangent2End: CGPoint(x: 16, y: 16),
                radius: 4.5
            )

        case .regenerate:
            // No matching prepared SVG exists; preserve the established turn.
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
            path.move(to: CGPoint(x: 5, y: 12))
            path.addLine(to: CGPoint(x: 8.9, y: 12))
            path.addCurve(
                to: CGPoint(x: 14, y: 9.1),
                control1: CGPoint(x: 11.2, y: 12),
                control2: CGPoint(x: 12.5, y: 10.8)
            )
            path.addLine(to: CGPoint(x: 18.6, y: 4.5))
            path.move(to: CGPoint(x: 13.8, y: 4.5))
            path.addLine(to: CGPoint(x: 19.4, y: 4.5))
            path.addLine(to: CGPoint(x: 19.4, y: 10.1))
            path.move(to: CGPoint(x: 14.5, y: 13.7))
            path.addLine(to: CGPoint(x: 19.4, y: 18.6))
            path.move(to: CGPoint(x: 13.8, y: 19.3))
            path.addLine(to: CGPoint(x: 19.4, y: 19.3))
            path.addLine(to: CGPoint(x: 19.4, y: 13.7))

        case .plus:
            path.move(to: CGPoint(x: 12, y: 5))
            path.addLine(to: CGPoint(x: 12, y: 19))
            path.move(to: CGPoint(x: 5, y: 12))
            path.addLine(to: CGPoint(x: 19, y: 12))

        case .send:
            // The prepared SVG's circle is composed in `ChatView`; this path
            // is its contrasting arrow on the same 24-unit view box.
            path.move(to: CGPoint(x: 12, y: 17.2))
            path.addLine(to: CGPoint(x: 12, y: 6.8))
            path.move(to: CGPoint(x: 7.6, y: 11.2))
            path.addLine(to: CGPoint(x: 12, y: 6.8))
            path.addLine(to: CGPoint(x: 16.4, y: 11.2))

        case .moreVertical:
            path.addEllipse(
                in: CGRect(x: 10.4, y: 3.4, width: 3.2, height: 3.2)
            )
            path.addEllipse(
                in: CGRect(x: 10.4, y: 10.4, width: 3.2, height: 3.2)
            )
            path.addEllipse(
                in: CGRect(x: 10.4, y: 17.4, width: 3.2, height: 3.2)
            )

        case .delete:
            path.move(to: CGPoint(x: 3.5, y: 6.9))
            path.addLine(to: CGPoint(x: 20.5, y: 6.9))
            path.move(to: CGPoint(x: 9.3, y: 6.9))
            path.addLine(to: CGPoint(x: 9.3, y: 5))
            path.addArc(
                tangent1End: CGPoint(x: 9.3, y: 3.2),
                tangent2End: CGPoint(x: 11.1, y: 3.2),
                radius: 1.8
            )
            path.addLine(to: CGPoint(x: 12.9, y: 3.2))
            path.addArc(
                tangent1End: CGPoint(x: 14.7, y: 3.2),
                tangent2End: CGPoint(x: 14.7, y: 5),
                radius: 1.8
            )
            path.addLine(to: CGPoint(x: 14.7, y: 6.9))
            path.move(to: CGPoint(x: 5.9, y: 6.9))
            let lowerLeadingArcStart = CGPoint(x: 6.7, y: 16.3)
            path.addLine(to: lowerLeadingArcStart)
            addSVGCircleArc(
                to: &path,
                from: lowerLeadingArcStart,
                to: CGPoint(x: 10.8, y: 20.1),
                radius: 4.1,
                sweepsForward: false
            )
            path.addLine(to: CGPoint(x: 13.2, y: 20.1))
            let lowerTrailingArcStart = CGPoint(x: 13.2, y: 20.1)
            addSVGCircleArc(
                to: &path,
                from: lowerTrailingArcStart,
                to: CGPoint(x: 17.3, y: 16.3),
                radius: 4.1,
                sweepsForward: false
            )
            path.addLine(to: CGPoint(x: 18.1, y: 6.9))

        case .shield:
            path.move(to: CGPoint(x: 12, y: 3.2))
            path.addLine(to: CGPoint(x: 19.4, y: 6))
            path.addLine(to: CGPoint(x: 19.4, y: 12.1))
            path.addCurve(
                to: CGPoint(x: 12, y: 20.8),
                control1: CGPoint(x: 19.4, y: 16.4),
                control2: CGPoint(x: 16.4, y: 19.5)
            )
            path.addCurve(
                to: CGPoint(x: 4.6, y: 12.1),
                control1: CGPoint(x: 7.6, y: 19.5),
                control2: CGPoint(x: 4.6, y: 16.4)
            )
            path.addLine(to: CGPoint(x: 4.6, y: 6))
            path.closeSubpath()
            path.move(to: CGPoint(x: 8.9, y: 11.9))
            path.addLine(to: CGPoint(x: 11.2, y: 14.2))
            path.addLine(to: CGPoint(x: 15.2, y: 10))

        case .settings:
            path.move(to: CGPoint(x: 12, y: 3.4))
            path.addCurve(
                to: CGPoint(x: 14, y: 4.54),
                control1: CGPoint(x: 12.75, y: 3.42),
                control2: CGPoint(x: 13.49, y: 3.84)
            )
            path.addCurve(
                to: CGPoint(x: 15.37, y: 6.16),
                control1: CGPoint(x: 14.51, y: 5.23),
                control2: CGPoint(x: 14.86, y: 5.87)
            )
            path.addCurve(
                to: CGPoint(x: 17.57, y: 6.43),
                control1: CGPoint(x: 15.89, y: 6.44),
                control2: CGPoint(x: 16.68, y: 6.35)
            )
            path.addCurve(
                to: CGPoint(x: 19.45, y: 7.7),
                control1: CGPoint(x: 18.45, y: 6.52),
                control2: CGPoint(x: 19.09, y: 7.04)
            )
            path.addCurve(
                to: CGPoint(x: 19.46, y: 10),
                control1: CGPoint(x: 19.8, y: 8.36),
                control2: CGPoint(x: 19.81, y: 9.21)
            )
            path.addCurve(
                to: CGPoint(x: 18.75, y: 12),
                control1: CGPoint(x: 19.12, y: 10.79),
                control2: CGPoint(x: 18.74, y: 11.41)
            )
            path.addCurve(
                to: CGPoint(x: 19.6, y: 14.04),
                control1: CGPoint(x: 18.76, y: 12.59),
                control2: CGPoint(x: 19.24, y: 13.23)
            )
            path.addCurve(
                to: CGPoint(x: 19.45, y: 16.3),
                control1: CGPoint(x: 19.97, y: 14.85),
                control2: CGPoint(x: 19.84, y: 15.66)
            )
            path.addCurve(
                to: CGPoint(x: 17.46, y: 17.46),
                control1: CGPoint(x: 19.05, y: 16.94),
                control2: CGPoint(x: 18.32, y: 17.37)
            )
            path.addCurve(
                to: CGPoint(x: 15.37, y: 17.84),
                control1: CGPoint(x: 16.61, y: 17.56),
                control2: CGPoint(x: 15.88, y: 17.54)
            )
            path.addCurve(
                to: CGPoint(x: 14.04, y: 19.6),
                control1: CGPoint(x: 14.87, y: 18.15),
                control2: CGPoint(x: 14.55, y: 18.88)
            )
            path.addCurve(
                to: CGPoint(x: 12, y: 20.6),
                control1: CGPoint(x: 13.52, y: 20.33),
                control2: CGPoint(x: 12.75, y: 20.62)
            )
            path.addCurve(
                to: CGPoint(x: 10, y: 19.46),
                control1: CGPoint(x: 11.25, y: 20.58),
                control2: CGPoint(x: 10.51, y: 20.16)
            )
            path.addCurve(
                to: CGPoint(x: 8.63, y: 17.84),
                control1: CGPoint(x: 9.49, y: 18.77),
                control2: CGPoint(x: 9.14, y: 18.13)
            )
            path.addCurve(
                to: CGPoint(x: 6.43, y: 17.57),
                control1: CGPoint(x: 8.11, y: 17.56),
                control2: CGPoint(x: 7.32, y: 17.65)
            )
            path.addCurve(
                to: CGPoint(x: 4.55, y: 16.3),
                control1: CGPoint(x: 5.55, y: 17.48),
                control2: CGPoint(x: 4.91, y: 16.96)
            )
            path.addCurve(
                to: CGPoint(x: 4.54, y: 14),
                control1: CGPoint(x: 4.2, y: 15.64),
                control2: CGPoint(x: 4.19, y: 14.79)
            )
            path.addCurve(
                to: CGPoint(x: 5.25, y: 12),
                control1: CGPoint(x: 4.88, y: 13.21),
                control2: CGPoint(x: 5.26, y: 12.59)
            )
            path.addCurve(
                to: CGPoint(x: 4.4, y: 9.96),
                control1: CGPoint(x: 5.24, y: 11.41),
                control2: CGPoint(x: 4.76, y: 10.77)
            )
            path.addCurve(
                to: CGPoint(x: 4.55, y: 7.7),
                control1: CGPoint(x: 4.03, y: 9.15),
                control2: CGPoint(x: 4.16, y: 8.34)
            )
            path.addCurve(
                to: CGPoint(x: 6.54, y: 6.54),
                control1: CGPoint(x: 4.95, y: 7.06),
                control2: CGPoint(x: 5.68, y: 6.63)
            )
            path.addCurve(
                to: CGPoint(x: 8.63, y: 6.16),
                control1: CGPoint(x: 7.39, y: 6.44),
                control2: CGPoint(x: 8.12, y: 6.46)
            )
            path.addCurve(
                to: CGPoint(x: 9.96, y: 4.4),
                control1: CGPoint(x: 9.13, y: 5.85),
                control2: CGPoint(x: 9.45, y: 5.12)
            )
            path.addCurve(
                to: CGPoint(x: 12, y: 3.4),
                control1: CGPoint(x: 10.48, y: 3.67),
                control2: CGPoint(x: 11.25, y: 3.38)
            )
            path.closeSubpath()
            path.addEllipse(
                in: CGRect(x: 9.8, y: 9.8, width: 4.4, height: 4.4)
            )

        case .waveform:
            path.move(to: CGPoint(x: 5.4, y: 10.6))
            path.addLine(to: CGPoint(x: 5.4, y: 13.4))
            path.move(to: CGPoint(x: 10.4, y: 6.4))
            path.addLine(to: CGPoint(x: 10.4, y: 17.6))
            path.move(to: CGPoint(x: 15, y: 8.8))
            path.addLine(to: CGPoint(x: 15, y: 15.2))
            path.move(to: CGPoint(x: 19.4, y: 10.7))
            path.addLine(to: CGPoint(x: 19.4, y: 13.3))

        case .check:
            path.move(to: CGPoint(x: 5, y: 12.5))
            path.addLine(to: CGPoint(x: 10, y: 17.5))
            path.addLine(to: CGPoint(x: 19, y: 6.5))

        case .search:
            path.addEllipse(
                in: CGRect(x: 4, y: 4, width: 13.6, height: 13.6)
            )
            path.move(to: CGPoint(x: 15.7, y: 15.7))
            path.addLine(to: CGPoint(x: 20.6, y: 20.6))

        case .close:
            path.move(to: CGPoint(x: 5.4, y: 5.4))
            path.addLine(to: CGPoint(x: 18.6, y: 18.6))
            path.move(to: CGPoint(x: 18.6, y: 5.4))
            path.addLine(to: CGPoint(x: 5.4, y: 18.6))

        case .expand:
            path.move(to: CGPoint(x: 6, y: 18))
            path.addLine(to: CGPoint(x: 18, y: 6))
            path.move(to: CGPoint(x: 10, y: 6))
            path.addLine(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 18, y: 14))

        case .collapse:
            path.move(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 18))
            path.move(to: CGPoint(x: 6, y: 10))
            path.addLine(to: CGPoint(x: 6, y: 18))
            path.addLine(to: CGPoint(x: 14, y: 18))
        }
    }

    /// Converts the circular subset of SVG's `A` command into a native arc.
    ///
    /// The prepared icons use only equal x/y radii, zero rotation, and the
    /// short arc, so this preserves their endpoints and circular geometry
    /// without approximating them with Bézier curves.
    private func addSVGCircleArc(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        radius requestedRadius: CGFloat,
        sweepsForward: Bool
    ) {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let chord = hypot(deltaX, deltaY)
        guard chord > .ulpOfOne else {
            return
        }

        let radius = max(requestedRadius, chord / 2)
        let midpoint = CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2
        )
        let centerOffset = sqrt(
            max(radius * radius - chord * chord / 4, 0)
        )
        let perpendicular = CGVector(
            dx: -deltaY / chord,
            dy: deltaX / chord
        )
        let centers = [
            CGPoint(
                x: midpoint.x + perpendicular.dx * centerOffset,
                y: midpoint.y + perpendicular.dy * centerOffset
            ),
            CGPoint(
                x: midpoint.x - perpendicular.dx * centerOffset,
                y: midpoint.y - perpendicular.dy * centerOffset
            ),
        ]

        let candidate = centers
            .map { center -> (CGPoint, Double, Double) in
                let startAngle = atan2(
                    start.y - center.y,
                    start.x - center.x
                )
                let endAngle = atan2(
                    end.y - center.y,
                    end.x - center.x
                )
                let span = positiveAngle(
                    sweepsForward
                        ? endAngle - startAngle
                        : startAngle - endAngle
                )
                return (center, startAngle, span)
            }
            .min { $0.2 < $1.2 }

        guard let candidate else {
            return
        }
        let endAngle = sweepsForward
            ? candidate.1 + candidate.2
            : candidate.1 - candidate.2
        path.addArc(
            center: candidate.0,
            radius: radius,
            startAngle: .radians(candidate.1),
            endAngle: .radians(endAngle),
            clockwise: !sweepsForward
        )
    }

    private func positiveAngle(_ angle: Double) -> Double {
        let fullTurn = Double.pi * 2
        let remainder = angle.truncatingRemainder(dividingBy: fullTurn)
        return remainder >= 0 ? remainder : remainder + fullTurn
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
        Group {
            if glyph == .moreVertical {
                LorepiaGlyphShape(glyph: glyph)
                    .fill()
            } else {
                LorepiaGlyphShape(glyph: glyph)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth:
                                glyph.stroke
                                * (size / LorepiaGlyph.grid),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

/// Pairs a title with a LorePia-drawn glyph anywhere SwiftUI expects a label.
///
/// Use this instead of falling back to an SF Symbol when the custom family
/// already has a semantic match. The icon follows Dynamic Type while keeping
/// the title available to LorePia-owned label surfaces and toolbars.
public struct LorepiaGlyphLabel: View {
    private let title: String
    private let glyph: LorepiaGlyph

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 18

    public init(
        _ title: String,
        glyph: LorepiaGlyph,
        size: CGFloat = 18
    ) {
        self.title = title
        self.glyph = glyph
        _scaledSize = ScaledMetric(
            wrappedValue: size,
            relativeTo: .body
        )
    }

    public var body: some View {
        Label {
            Text(title)
        } icon: {
            LorepiaGlyphView(glyph, size: resolvedSize)
        }
    }

    private var resolvedSize: CGFloat {
        min(max(scaledSize, 15), 28)
    }
}

private struct LorepiaGlyphShape: Shape {
    let glyph: LorepiaGlyph

    func path(in rect: CGRect) -> Path {
        glyph.path(in: rect)
    }
}
