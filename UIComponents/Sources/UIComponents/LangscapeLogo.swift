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
    private let brand: Brand

    // A clean, monochrome mark. Defaults to the DesignSystem primary color.
    public init(style: Style = .full,
                glyphSize: CGFloat = 56,
                spacing: CGFloat = 12,
                tint: Color = ColorPalette.primary.swiftUIColor,
                accentTint: Color = ColorPalette.accent.swiftUIColor,
                assetName: String? = nil,
                brand: Brand = .chatPin) {
        self.style = style
        self.glyphSize = glyphSize
        self.spacing = spacing
        self.tint = tint
        self.assetName = assetName
        self.brand = brand
        self.accentTint = accentTint
    }

    public var body: some View {
        HStack(spacing: style == .full ? spacing : 0) {
            glyph
            if style == .full { wordmark }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Langscape")
    }

    // MARK: - Elements

    @ViewBuilder
    private var glyph: some View {
        if let name = assetName, let image = Self.loadImage(named: name) {
            image
                .renderingMode(.original) // preserve brand colors
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
        } else {
            switch brand {
            case .chatPin:
                ChatPinMark(size: glyphSize, tint: tint, accent: accentTint)
            case .speechPin:
                SpeechPinMark(size: glyphSize, tint: tint, accent: accentTint)
            case .context:
                ContextMark(size: glyphSize, tint: tint, accent: accentTint)
            case .topoPin:
                TopoPinMark(size: glyphSize, tint: tint, accent: accentTint)
            case .monogram:
                MonogramMark(size: glyphSize, tint: tint)
            }
        }
    }

    private var wordmark: some View {
        Text("Langscape")
            .font(.system(size: glyphSize * 0.5, weight: .semibold, design: .rounded))
            .kerning(0.5)
            .foregroundStyle(tint)
    }
}

// MARK: - Globe + Chat bubble mark

fileprivate struct ContextMark: View {
    let size: CGFloat
    let tint: Color
    let accent: Color
    private var lineWidth: CGFloat { max(1.2, size * 0.075) }

    var body: some View {
        ZStack {
            // Minimal corner notches (lighter than a full bounding box)
            Path { p in
                let inset = size * 0.16
                let len = size * 0.09

                // top-left
                p.move(to: CGPoint(x: inset, y: inset + len))
                p.addLine(to: CGPoint(x: inset, y: inset))
                p.addLine(to: CGPoint(x: inset + len, y: inset))

                // top-right
                p.move(to: CGPoint(x: size - inset - len, y: inset))
                p.addLine(to: CGPoint(x: size - inset, y: inset))
                p.addLine(to: CGPoint(x: size - inset, y: inset + len))

                // bottom-right
                p.move(to: CGPoint(x: size - inset, y: size - inset - len))
                p.addLine(to: CGPoint(x: size - inset, y: size - inset))
                p.addLine(to: CGPoint(x: size - inset - len, y: size - inset))

                // bottom-left
                p.move(to: CGPoint(x: inset + len, y: size - inset))
                p.addLine(to: CGPoint(x: inset, y: size - inset))
                p.addLine(to: CGPoint(x: inset, y: size - inset - len))
            }
            .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: lineWidth * 0.75, lineCap: .round, lineJoin: .round))

            // Professional bubble with integrated pointer (single path, crisp join)
            let bubbleStroke = max(1, lineWidth * 0.6)
            BubblePinShape()
                .fill(tint.opacity(0.10))
                .overlay(
                    BubblePinShape().stroke(tint.opacity(0.85), lineWidth: bubbleStroke)
                )

            // Subtle accent line inside the bubble (hint of red without adding clutter)
            let accentW = size * 0.58 * 0.34
            let accentH = (size * 0.26) * 0.18
            Capsule(style: .circular)
                .fill(accent.opacity(0.85))
                .frame(width: accentW, height: accentH)
                .offset(y: -size * 0.02)

            // No accent dot; keep the mark clean
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

// MARK: - Speech bubble styled as a map marker
fileprivate struct SpeechPinMark: View {
    let size: CGFloat
    let tint: Color
    let accent: Color
    private var lineWidth: CGFloat { max(1.3, size * 0.075) }

    var body: some View {
        ZStack {
            // Outline
            SpeechPinShape()
                .stroke(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .top, endPoint: .bottom), lineWidth: lineWidth)

            // Soft fill
            SpeechPinShape()
                .fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom))

            // "Text" lines inside the bubble body
            VStack(spacing: size * 0.06) {
                RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                    .fill(tint.opacity(0.85))
                    .frame(width: size * 0.46, height: max(1, lineWidth * 0.55))
                RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                    .fill(tint.opacity(0.75))
                    .frame(width: size * 0.38, height: max(1, lineWidth * 0.5))
                RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                    .fill(accent.opacity(0.85))
                    .frame(width: size * 0.22, height: max(1, lineWidth * 0.5))
            }
            .offset(y: -size * 0.12)
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

fileprivate struct SpeechPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        
        // Circular head (clear map-pin identity)
        let circleR = min(w, h) * 0.32
        let circleCenter = CGPoint(x: cx, y: rect.minY + h * 0.42)
        // Tangent points where the pointer attaches to the circle
        let theta = CGFloat(52.0) * .pi / 180 // 52° from vertical
        let leftT = CGPoint(x: circleCenter.x - circleR * cos(theta),
                            y: circleCenter.y + circleR * sin(theta))
        let rightT = CGPoint(x: circleCenter.x + circleR * cos(theta),
                             y: circleCenter.y + circleR * sin(theta))
        // Pointer tip
        let tipY = rect.maxY - h * 0.06
        let tip = CGPoint(x: cx, y: tipY)

        // Build pin: right tangent → tip → left tangent → arc across the top back to right tangent
        p.move(to: rightT)
        p.addCurve(
            to: tip,
            control1: CGPoint(x: rightT.x - circleR * 0.18, y: rightT.y + h * 0.06),
            control2: CGPoint(x: cx + circleR * 0.28, y: tipY - h * 0.02)
        )
        p.addCurve(
            to: leftT,
            control1: CGPoint(x: cx - circleR * 0.28, y: tipY - h * 0.02),
            control2: CGPoint(x: leftT.x + circleR * 0.18, y: leftT.y + h * 0.06)
        )

        // Arc over the circular head
        let start = Angle(degrees: 180 + 52)
        let end = Angle(degrees: 360 - 52)
        p.addArc(center: circleCenter, radius: circleR, startAngle: start, endAngle: end, clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Bubble with integrated, centered pointer
fileprivate struct BubblePinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // Bubble metrics
        let bubbleW = w * 0.58
        let bubbleH = h * 0.26
        let tailH = h * 0.10
        let tailW = bubbleW * 0.28
        let cx = w * 0.5
        let bubbleMidY = h * 0.50 - tailH * 0.18
        let bubble = CGRect(x: (w - bubbleW) / 2, y: bubbleMidY - bubbleH / 2, width: bubbleW, height: bubbleH)
        let r = bubbleH * 0.5

        // Points
        let baseY = bubble.maxY
        let joinL = CGPoint(x: cx - tailW * 0.5, y: baseY)
        let joinR = CGPoint(x: cx + tailW * 0.5, y: baseY)
        let tip = CGPoint(x: cx, y: min(h - h * 0.06, baseY + tailH))

        // Start at top-left corner
        p.move(to: CGPoint(x: bubble.minX + r, y: bubble.minY))
        // Top edge + top-right arc
        p.addLine(to: CGPoint(x: bubble.maxX - r, y: bubble.minY))
        p.addArc(center: CGPoint(x: bubble.maxX - r, y: bubble.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        // Right edge to bottom-right arc
        p.addLine(to: CGPoint(x: bubble.maxX, y: bubble.maxY - r))
        p.addArc(center: CGPoint(x: bubble.maxX - r, y: bubble.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Bottom edge to joinR
        p.addLine(to: joinR)
        // Pointer (rounded V)
        p.addQuadCurve(to: tip, control: CGPoint(x: cx + tailW * 0.40, y: baseY + tailH * 0.55))
        p.addQuadCurve(to: joinL, control: CGPoint(x: cx - tailW * 0.40, y: baseY + tailH * 0.55))
        // Bottom edge to bottom-left arc
        p.addLine(to: CGPoint(x: bubble.minX + r, y: bubble.maxY))
        p.addArc(center: CGPoint(x: bubble.minX + r, y: bubble.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        // Left edge back to start
        p.addLine(to: CGPoint(x: bubble.minX, y: bubble.minY + r))
        p.addArc(center: CGPoint(x: bubble.minX + r, y: bubble.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - ChatBubble inside a refined map pin
fileprivate struct ChatPinMark: View {
    let size: CGFloat
    let tint: Color
    let accent: Color
    private var lineWidth: CGFloat { max(1.3, size * 0.075) }

    var body: some View {
        ZStack {
            // Outer refined map pin (circle head + elegant pointer)
            PinV2Shape()
                .stroke(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .top, endPoint: .bottom), lineWidth: lineWidth)
            PinV2Shape()
                .fill(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom))

            // Inner chat bubble with three dots (centered within the head)
            let bw = size * 0.56
            let bh = size * 0.26
            let by = -size * 0.10

            ZStack {
                RoundedRectangle(cornerRadius: bh * 0.5, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: bh * 0.5, style: .continuous)
                            .stroke(tint.opacity(0.9), lineWidth: max(1, lineWidth * 0.6))
                    )
                    .frame(width: bw, height: bh)

                // Dots
                HStack(spacing: bw * 0.10) {
                    Circle().fill(accent).frame(width: bh*0.22, height: bh*0.22)
                    Circle().fill(accent).frame(width: bh*0.22, height: bh*0.22)
                    Circle().fill(accent).frame(width: bh*0.22, height: bh*0.22)
                }
            }
            .offset(y: by)
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

fileprivate struct PinV2Shape: Shape {
    // Ratios producing a familiar, balanced map pin
    var headRadiusK: CGFloat = 0.34
    var headCenterYK: CGFloat = 0.40
    var tipYK: CGFloat = 0.88
    var attachAngleDeg: CGFloat = 50

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX

        let r = min(w, h) * headRadiusK
        let cy = rect.minY + h * headCenterYK
        let angle = attachAngleDeg * .pi / 180
        let rightT = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
        let leftT = CGPoint(x: cx - r * cos(angle), y: cy + r * sin(angle))
        let tipY = rect.minY + h * tipYK
        let tip = CGPoint(x: cx, y: tipY)

        p.move(to: rightT)
        p.addCurve(
            to: tip,
            control1: CGPoint(x: rightT.x - r * 0.20, y: rightT.y + h * 0.06),
            control2: CGPoint(x: cx + r * 0.30, y: tipY - h * 0.02)
        )
        p.addCurve(
            to: leftT,
            control1: CGPoint(x: cx - r * 0.30, y: tipY - h * 0.02),
            control2: CGPoint(x: leftT.x + r * 0.20, y: leftT.y + h * 0.06)
        )

        // Arc across the top of the circular head
        let start = Angle(radians: Double.pi + Double(angle))
        let end = Angle(radians: Double(2 * Double.pi) - Double(angle))
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: start, endAngle: end, clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Topographic pin + speech motif
fileprivate struct TopoPinMark: View {
    let size: CGFloat
    let tint: Color
    let accent: Color
    private var lineWidth: CGFloat { max(1.4, size * 0.075) }

    var body: some View {
        ZStack {
            // Pin outline
            TopoPinShape()
                .stroke(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .top, endPoint: .bottom), lineWidth: lineWidth)

            // Subtle fill
            TopoPinShape()
                .fill(LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.04)], startPoint: .top, endPoint: .bottom))

            // Contour lines clipped to the pin shape
            ZStack {
                contour(yFactor: 0.46, amplitude: size * 0.06)
                    .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: max(1, lineWidth * 0.6), lineCap: .round, lineJoin: .round))
                contour(yFactor: 0.60, amplitude: size * 0.05)
                    .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: max(1, lineWidth * 0.5), lineCap: .round, lineJoin: .round))
                contour(yFactor: 0.72, amplitude: size * 0.04)
                    .stroke(tint.opacity(0.65), style: StrokeStyle(lineWidth: max(1, lineWidth * 0.45), lineCap: .round, lineJoin: .round))
            }
            .clipShape(TopoPinShape())

            // Tiny accent dot suggesting speech/point of interest
            Circle()
                .fill(accent)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: size * 0.24, y: size * 0.06)
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }

    private func contour(yFactor: CGFloat, amplitude: CGFloat) -> Path {
        var p = Path()
        let w = size
        let h = size
        let y = h * yFactor
        let x0 = w * 0.18
        let x3 = w * 0.82
        let c = (x3 - x0) / 3
        p.move(to: CGPoint(x: x0, y: y))
        p.addCurve(
            to: CGPoint(x: x0 + 2*c, y: y),
            control1: CGPoint(x: x0 + 0.75*c, y: y - amplitude),
            control2: CGPoint(x: x0 + 1.25*c, y: y + amplitude)
        )
        p.addCurve(
            to: CGPoint(x: x3, y: y),
            control1: CGPoint(x: x0 + 2.75*c, y: y - amplitude),
            control2: CGPoint(x: x0 + 2.25*c, y: y + amplitude)
        )
        return p
    }
}

fileprivate struct TopoPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.height * 0.42
        let r = min(w, h) * 0.34

        // Start at top
        p.move(to: CGPoint(x: cx, y: cy - r))
        // Left side down to belly
        p.addCurve(
            to: CGPoint(x: rect.minX + w*0.20, y: cy + r*0.55),
            control1: CGPoint(x: cx - r*0.95, y: cy - r*0.95),
            control2: CGPoint(x: rect.minX + w*0.18, y: cy + r*0.05)
        )
        // Curve to tip
        p.addQuadCurve(
            to: CGPoint(x: cx, y: rect.maxY - h*0.10),
            control: CGPoint(x: rect.minX + w*0.18, y: rect.maxY - h*0.02)
        )
        // Curve up right side
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - w*0.20, y: cy + r*0.55),
            control: CGPoint(x: rect.maxX - w*0.18, y: rect.maxY - h*0.02)
        )
        // Back to top
        p.addCurve(
            to: CGPoint(x: cx, y: cy - r),
            control1: CGPoint(x: rect.maxX - w*0.18, y: cy + r*0.05),
            control2: CGPoint(x: cx + r*0.95, y: cy - r*0.95)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Minimal LS monogram (fallback)
fileprivate struct MonogramMark: View {
    let size: CGFloat
    let tint: Color
    private var lineWidth: CGFloat { max(1.6, size * 0.10) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(tint.opacity(0.95), lineWidth: max(1.2, size * 0.075))

            Path { p in
                let w = size
                let h = size
                let inset = size * 0.26
                // L
                p.move(to: CGPoint(x: inset, y: inset))
                p.addLine(to: CGPoint(x: inset, y: h - inset))
                p.addLine(to: CGPoint(x: w * 0.70, y: h - inset))
                // S
                let midY = h * 0.50
                p.move(to: CGPoint(x: w - inset, y: inset))
                p.addCurve(to: CGPoint(x: inset, y: midY),
                           control1: CGPoint(x: w * 0.75, y: inset),
                           control2: CGPoint(x: w * 0.32, y: midY - size * 0.22))
                p.addCurve(to: CGPoint(x: w - inset, y: h - inset),
                           control1: CGPoint(x: w * 0.18, y: midY + size * 0.22),
                           control2: CGPoint(x: w * 0.68, y: h - inset))
            }
            .stroke(tint.opacity(0.95), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .drawingGroup()
    }
}

// MARK: - Asset loading (main bundle preferred)
extension LangscapeLogo {
    static func loadImage(named name: String) -> Image? {
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
