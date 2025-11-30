import Foundation
import CoreGraphics
import CoreText

let outputPath = "UIComponents/Sources/UIComponents/Resources/BrandAssets.xcassets/LangscapeBrandmark.imageset/LangscapeBrandmark.pdf"
let width: CGFloat = 1200
let height: CGFloat = 600
var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)

guard let context = CGContext(URL(fileURLWithPath: outputPath) as CFURL, mediaBox: &mediaBox, nil) else {
    fatalError("Unable to create PDF context")
}

extension Int {
    var double: Double { Double(self) }
}

func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    let base: CGFloat = 200
    let scale = min(rect.width, rect.height) / base
    let offsetX = rect.midX - base * 0.5 * scale
    let offsetY = rect.midY - base * 0.5 * scale
    return CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
}

func drawSVGCameraBracket(in ctx: CGContext, rect: CGRect, color: CGColor, lineWidth: CGFloat) {
    let path = CGMutablePath()
    let radius: CGFloat = 10

    // top-left
    path.move(to: point(60, 20, in: rect))
    path.addLine(to: point(20, 20, in: rect))
    path.addArc(center: point(20, 30, in: rect), radius: radius, startAngle: .pi * 1.5, endAngle: .pi, clockwise: true)
    path.addLine(to: point(10, 70, in: rect))

    // bottom-left
    path.move(to: point(10, 130, in: rect))
    path.addLine(to: point(10, 170, in: rect))
    path.addArc(center: point(20, 170, in: rect), radius: radius, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    path.addLine(to: point(60, 180, in: rect))

    // bottom-right
    path.move(to: point(140, 180, in: rect))
    path.addLine(to: point(180, 180, in: rect))
    path.addArc(center: point(180, 170, in: rect), radius: radius, startAngle: .pi / 2, endAngle: 0, clockwise: true)
    path.addLine(to: point(190, 130, in: rect))

    // top-right
    path.move(to: point(190, 70, in: rect))
    path.addLine(to: point(190, 30, in: rect))
    path.addArc(center: point(180, 30, in: rect), radius: radius, startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
    path.addLine(to: point(140, 20, in: rect))

    ctx.addPath(path.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

func drawSVGPin(in ctx: CGContext, rect: CGRect, color: CGColor, lineWidth: CGFloat) {
    let outer = CGMutablePath()
    outer.move(to: point(100, 40, in: rect))
    outer.addCurve(to: point(62, 84, in: rect), control1: point(80, 32, in: rect), control2: point(65, 56, in: rect))
    outer.addCurve(to: point(100, 150, in: rect), control1: point(58, 115, in: rect), control2: point(82, 146, in: rect))
    outer.addCurve(to: point(138, 84, in: rect), control1: point(118, 146, in: rect), control2: point(142, 115, in: rect))
    outer.addCurve(to: point(100, 40, in: rect), control1: point(135, 56, in: rect), control2: point(122, 32, in: rect))
    outer.closeSubpath()

    let base: CGFloat = 200
    let scale = min(rect.width, rect.height) / base
    let circleCenter = point(100, 80, in: rect)
    let innerRadius = 15 * scale
    let circleRect = CGRect(x: circleCenter.x - innerRadius, y: circleCenter.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
    let circle = CGPath(ellipseIn: circleRect, transform: nil)

    ctx.addPath(outer)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.addPath(circle)
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()
}

func drawWordmark(in ctx: CGContext, text: String, fontSize: CGFloat, color: CGColor, origin: CGPoint) {
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let textPosition = CGPoint(x: origin.x, y: origin.y - bounds.midY)
    ctx.textPosition = textPosition
    CTLineDraw(line, ctx)
}

let primary = CGColor(red: 0x1D.double/255.0, green: 0x35.double/255.0, blue: 0x57.double/255.0, alpha: 1)
let accent = CGColor(red: 0xE6.double/255.0, green: 0x39.double/255.0, blue: 0x46.double/255.0, alpha: 1)

context.beginPDFPage(nil)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0))
context.fill(mediaBox)

let glyphSize: CGFloat = 420
let glyphRect = CGRect(x: 120, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize)
let strokeWidth = glyphSize * (5.0 / 200.0)

drawSVGCameraBracket(in: context, rect: glyphRect, color: primary, lineWidth: strokeWidth)
drawSVGPin(in: context, rect: glyphRect.insetBy(dx: glyphSize * 0.02, dy: glyphSize * 0.02), color: primary, lineWidth: strokeWidth)

let accentCenter = point(100, 80, in: glyphRect)
let accentRadius = 15 * (glyphSize / 200)
context.setFillColor(accent)
context.addEllipse(in: CGRect(x: accentCenter.x - accentRadius, y: accentCenter.y - accentRadius, width: accentRadius * 2, height: accentRadius * 2))
context.fillPath()

let wordmarkX = glyphRect.maxX + 90
let baselineY = height / 2 + 20
drawWordmark(in: context, text: "LANGSCAPE", fontSize: 190, color: primary, origin: CGPoint(x: wordmarkX, y: baselineY))

context.endPDFPage()
context.closePDF()
