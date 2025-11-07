import SwiftUI
import DesignSystem

public struct LangscapeLogo: View {
    public enum Style { case full, mark }

    private let style: Style
    private let glyphSize: CGFloat
    private let spacing: CGFloat

    public init(style: Style = .full, glyphSize: CGFloat = 56, spacing: CGFloat = 12) {
        self.style = style
        self.glyphSize = glyphSize
        self.spacing = spacing
    }

    public var body: some View {
        HStack(spacing: style == .full ? spacing : 0) {
            glyph
            if style == .full {
                wordmark
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Langscape")
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [ColorPalette.accent.swiftUIColor, ColorPalette.primary.swiftUIColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: glyphSize * 0.28, style: .continuous)
                .fill(gradient)
                .shadow(color: .black.opacity(0.25), radius: glyphSize * 0.12, x: 0, y: glyphSize * 0.06)

            Text("LS")
                .font(.system(size: glyphSize * 0.52, weight: .heavy, design: .rounded))
                .kerning(0.5)
                .foregroundStyle(Color.white)
        }
        .frame(width: glyphSize, height: glyphSize)
    }

    private var wordmark: some View {
        Text("Langscape")
            .font(.system(size: glyphSize * 0.52, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(gradient)
    }
}

