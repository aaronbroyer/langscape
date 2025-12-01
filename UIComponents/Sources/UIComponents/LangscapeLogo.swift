import SwiftUI
import DesignSystem

public struct LangscapeLogo: View {
    public enum Style { case full, mark }

    private let style: Style
    private let glyphSize: CGFloat
    private let spacing: CGFloat

    public init(
        style: Style = .full,
        glyphSize: CGFloat = 70,
        spacing: CGFloat = 15
    ) {
        self.style = style
        self.glyphSize = glyphSize
        self.spacing = spacing
    }

    public var body: some View {
        LogoContent(
            style: style,
            glyphSize: glyphSize,
            spacing: spacing,
            brandColor: ColorPalette.primary.swiftUIColor,
            accentColor: ColorPalette.accent.swiftUIColor
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Langscape")
    }
}

private struct LogoContent: View {
    let style: LangscapeLogo.Style
    let glyphSize: CGFloat
    let spacing: CGFloat
    let brandColor: Color
    let accentColor: Color

    private var effectiveSpacing: CGFloat { style == .full ? spacing : 0 }
    private var wordmarkSize: CGFloat { glyphSize * (52.0 / 70.0) }

    var body: some View {
        HStack(spacing: effectiveSpacing) {
            ExactLogoGlyph(
                size: glyphSize,
                strokeColor: brandColor,
                accentColor: accentColor
            )
            if style == .full {
                Text("LANGSCAPE")
                    .font(.system(size: wordmarkSize, weight: .heavy, design: .rounded))
                    .kerning(glyphSize * 0.015)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .foregroundStyle(brandColor)
            }
        }
        .padding(.vertical, 0)
    }
}

private struct ExactLogoGlyph: View {
    let size: CGFloat
    let strokeColor: Color
    let accentColor: Color

    private let baseSize: CGFloat = 70
    private var scale: CGFloat { size / baseSize }

    var body: some View {
        let stroke = StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round)

        ZStack {
            PreciseBracketShape()
                .stroke(strokeColor, style: stroke)
                .frame(width: size, height: size)

            PreciseMapPinShape()
                .stroke(strokeColor, style: stroke)
                .frame(width: 32 * scale, height: 44 * scale)
                .offset(y: 2 * scale)

            Circle()
                .fill(accentColor)
                .frame(width: 12 * scale, height: 12 * scale)
                .offset(y: -8 * scale)

            Circle()
                .stroke(strokeColor, lineWidth: 4 * scale)
                .frame(width: 12 * scale, height: 12 * scale)
                .offset(y: -8 * scale)
        }
        .frame(width: size, height: size)
    }
}

private struct PreciseBracketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let base: CGFloat = 70
        let scale = min(rect.width, rect.height) / base

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + x * scale,
                y: rect.minY + y * scale
            )
        }

        var path = Path()

        path.move(to: point(0, 20))
        path.addLine(to: point(0, 10))
        path.addArc(
            center: point(10, 10),
            radius: 10 * scale,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: point(25, 0))

        path.move(to: point(45, 0))
        path.addLine(to: point(60, 0))
        path.addArc(
            center: point(60, 10),
            radius: 10 * scale,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: point(70, 20))

        path.move(to: point(70, 50))
        path.addLine(to: point(70, 60))
        path.addArc(
            center: point(60, 60),
            radius: 10 * scale,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: point(45, 70))

        path.move(to: point(25, 70))
        path.addLine(to: point(10, 70))
        path.addArc(
            center: point(10, 60),
            radius: 10 * scale,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: point(0, 50))

        return path
    }
}

private struct PreciseMapPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let width = rect.width
        let height = rect.height
        let headRadius = width / 2
        let headCenterY = headRadius
        let tip = CGPoint(x: width / 2, y: height)

        path.move(to: tip)

        path.addCurve(
            to: CGPoint(x: 0, y: headCenterY),
            control1: CGPoint(x: width * 0.05, y: height * 0.65),
            control2: CGPoint(x: 0, y: headCenterY + headRadius * 0.5)
        )

        path.addArc(
            center: CGPoint(x: width / 2, y: headCenterY),
            radius: headRadius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )

        path.addCurve(
            to: tip,
            control1: CGPoint(x: width, y: headCenterY + headRadius * 0.5),
            control2: CGPoint(x: width * 0.95, y: height * 0.65)
        )

        path.closeSubpath()
        return path
    }
}
