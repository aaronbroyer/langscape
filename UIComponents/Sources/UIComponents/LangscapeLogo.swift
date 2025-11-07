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
            ContextMark(size: glyphSize, tint: tint)
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
    private var lineWidth: CGFloat { max(1.2, size * 0.075) }

    var body: some View {
        ZStack {
            // Viewfinder corners
            Path { p in
                let c = size * 0.16 // inset from edges
                let l = size * 0.24 // corner length

                // top-left
                p.move(to: CGPoint(x: c, y: c + l))
                p.addLine(to: CGPoint(x: c, y: c))
                p.addLine(to: CGPoint(x: c + l, y: c))

                // top-right
                p.move(to: CGPoint(x: size - c - l, y: c))
                p.addLine(to: CGPoint(x: size - c, y: c))
                p.addLine(to: CGPoint(x: size - c, y: c + l))

                // bottom-right
                p.move(to: CGPoint(x: size - c, y: size - c - l))
                p.addLine(to: CGPoint(x: size - c, y: size - c))
                p.addLine(to: CGPoint(x: size - c - l, y: size - c))

                // bottom-left
                p.move(to: CGPoint(x: c + l, y: size - c))
                p.addLine(to: CGPoint(x: c, y: size - c))
                p.addLine(to: CGPoint(x: c, y: size - c - l))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // Central label pill — represents a contextual label in scene
            Capsule(style: .circular)
                .fill(tint.opacity(0.12))
                .frame(width: size * 0.52, height: size * 0.22)
                .overlay(
                    Capsule(style: .circular)
                        .stroke(tint.opacity(0.9), lineWidth: max(1, lineWidth * 0.66))
                )

            // Small chat dot to suggest language/speech
            Circle()
                .fill(tint)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: size * 0.22, y: size * 0.22)
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
