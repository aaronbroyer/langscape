import SwiftUI
import DesignSystem
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct LangscapeLogo: View {
    public enum Style { case full, mark }
    public enum Brand { case chatPin, speechPin, context, topoPin, monogram }

    private let style: Style
    private let glyphSize: CGFloat
    private let spacing: CGFloat
    private let tint: Color
    private let accentTint: Color
    private let assetName: String?

    public init(style: Style = .full,
                glyphSize: CGFloat = 56,
                spacing: CGFloat = 12,
                tint: Color = ColorPalette.primary.swiftUIColor,
                accentTint: Color = ColorPalette.accent.swiftUIColor,
                assetName: String? = "LangscapeBrandmark",
                brand: Brand = .chatPin) {
        self.style = style
        self.glyphSize = glyphSize
        self.spacing = spacing
        self.tint = tint
        self.assetName = assetName
        self.accentTint = accentTint
        _ = brand
    }

    public var body: some View {
        if let asset = assetImage {
            asset
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(height: glyphSize)
                .accessibilityLabel("Langscape")
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        HStack(spacing: style == .full ? spacing : 0) {
            glyph
            if style == .full { wordmark }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Langscape")
    }

    @ViewBuilder
    private var glyph: some View {
        GradientCameraPinMark(size: glyphSize,
                              strokeColor: tint,
                              accentColor: accentTint)
    }

    private var wordmark: some View {
        Text("LANGSCAPE")
            .font(.system(size: glyphSize * 0.52, weight: .semibold, design: .rounded))
            .kerning(0.6)
            .foregroundStyle(tint)
    }

    private var assetImage: Image? {
        guard let name = assetName else { return nil }
        return LangscapeLogo.loadImage(named: name)
    }

    private static func loadImage(named name: String) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(named: name, in: .main, compatibleWith: nil) {
            return Image(uiImage: ui)
        }
        if let ui = UIImage(named: name, in: .module, compatibleWith: nil) {
            return Image(uiImage: ui)
        }
        return nil
        #elseif canImport(AppKit)
        if let ns = NSImage(named: NSImage.Name(name)) {
            return Image(nsImage: ns)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil), let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        if let url = Bundle.module.url(forResource: name, withExtension: nil), let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        return nil
        #else
        return nil
        #endif
    }
}

// MARK: - SVG Inspired Mark

fileprivate struct GradientCameraPinMark: View {
    let size: CGFloat
    let strokeColor: Color
    let accentColor: Color

    private var strokeWidth: CGFloat { max(1.2, size * (5.0 / 200.0)) }
    private var accentDiameter: CGFloat { size * (30.0 / 200.0) }
    private var accentOffsetY: CGFloat { size * ((80.0 - 100.0) / 200.0) }

    var body: some View {
        ZStack {
            SVGCameraBracketShape()
                .stroke(strokeColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            SVGLocationPinOutlineShape()
                .stroke(strokeColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(accentColor)
                .frame(width: accentDiameter, height: accentDiameter)
                .offset(y: accentOffsetY)
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

fileprivate struct SVGCameraBracketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base: CGFloat = 200
        let scale = min(rect.width, rect.height) / base
        let offsetX = rect.midX - base * 0.5 * scale
        let offsetY = rect.midY - base * 0.5 * scale
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }
        let radius = 10 * scale

        // top-left
        path.move(to: pt(60, 20))
        path.addLine(to: pt(20, 20))
        path.addArc(center: pt(20, 30), radius: radius, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: pt(10, 70))

        // bottom-left
        path.move(to: pt(10, 130))
        path.addLine(to: pt(10, 170))
        path.addArc(center: pt(20, 170), radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: pt(60, 180))

        // bottom-right
        path.move(to: pt(140, 180))
        path.addLine(to: pt(180, 180))
        path.addArc(center: pt(180, 170), radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: pt(190, 130))

        // top-right
        path.move(to: pt(190, 70))
        path.addLine(to: pt(190, 30))
        path.addArc(center: pt(180, 30), radius: radius, startAngle: .degrees(0), endAngle: .degrees(270), clockwise: true)
        path.addLine(to: pt(140, 20))

        return path
    }
}

fileprivate struct SVGLocationPinOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat, base: CGFloat, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }
        let base: CGFloat = 200
        let scale = min(rect.width, rect.height) / base
        let offsetX = rect.midX - base * 0.5 * scale
        let offsetY = rect.midY - base * 0.5 * scale

        var path = Path()
        path.move(to: pt(100, 40, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY))
        path.addCurve(to: pt(62, 84, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control1: pt(80, 32, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control2: pt(65, 56, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY))
        path.addCurve(to: pt(100, 150, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control1: pt(58, 115, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control2: pt(82, 146, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY))
        path.addCurve(to: pt(138, 84, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control1: pt(118, 146, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control2: pt(142, 115, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY))
        path.addCurve(to: pt(100, 40, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control1: pt(135, 56, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY),
                      control2: pt(122, 32, base: base, scale: scale, offsetX: offsetX, offsetY: offsetY))
        path.closeSubpath()
        return path
    }
}
