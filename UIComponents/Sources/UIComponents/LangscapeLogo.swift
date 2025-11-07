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

    private let style: Style
    private let glyphSize: CGFloat
    private let spacing: CGFloat
    private let tint: Color
    private let assetName: String?

    // A clean, monochrome mark. Defaults to the DesignSystem primary color.
    public init(style: Style = .full,
                glyphSize: CGFloat = 56,
                spacing: CGFloat = 12,
                tint: Color = ColorPalette.primary.swiftUIColor,
                assetName: String? = "LangscapeBrandmark") {
        self.style = style
        self.glyphSize = glyphSize
        self.spacing = spacing
        self.tint = tint
        self.assetName = assetName
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
            GlobeChatMark(size: glyphSize, tint: tint)
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

fileprivate struct GlobeChatMark: View {
    let size: CGFloat
    let tint: Color
    var lineWidth: CGFloat { max(1.25, size * 0.07) }

    var body: some View {
        ZStack {
            // Outer circle
            Circle()
                .stroke(tint, lineWidth: lineWidth)

            // Parallels and meridians clipped to circle
            ZStack {
                // Equator
                Rectangle()
                    .fill(tint)
                    .frame(height: lineWidth)

                // Parallels (top/bottom)
                Path(ellipseIn: CGRect(x: size * 0.12, y: size * 0.27, width: size * 0.76, height: size * 0.46))
                    .stroke(tint, lineWidth: lineWidth)
                Path(ellipseIn: CGRect(x: size * 0.12, y: size * 0.27, width: size * 0.76, height: size * 0.46))
                    .rotation(Angle(degrees: 180))
                    .stroke(tint, lineWidth: lineWidth)

                // Meridians (left/right)
                Path(ellipseIn: CGRect(x: size * 0.25, y: size * 0.08, width: size * 0.50, height: size * 0.84))
                    .stroke(tint, lineWidth: lineWidth)
                Path(ellipseIn: CGRect(x: size * 0.25, y: size * 0.08, width: size * 0.50, height: size * 0.84))
                    .rotation(Angle(degrees: 180))
                    .stroke(tint, lineWidth: lineWidth)
            }
            .clipShape(Circle().inset(by: lineWidth * 0.5))

            // Chat tail (minimal, attached to lower-right)
            Path { p in
                let r = size / 2
                p.move(to: CGPoint(x: r * 1.15, y: r * 1.10))
                p.addLine(to: CGPoint(x: r * 1.55, y: r * 1.42))
                p.addLine(to: CGPoint(x: r * 0.98, y: r * 1.42))
                p.closeSubpath()
            }
            .fill(tint)
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
