import SwiftUI
import DesignSystem

public struct LangscapeLogo: View {
    public enum Style { case full, mark }

    private let style: Style
    private let glyphSize: CGFloat
    private let spacing: CGFloat
    private let tint: Color

    // A clean, monochrome mark. Defaults to the DesignSystem primary color.
    public init(style: Style = .full, glyphSize: CGFloat = 56, spacing: CGFloat = 12, tint: Color = ColorPalette.primary.swiftUIColor) {
        self.style = style
        self.glyphSize = glyphSize
        self.spacing = spacing
        self.tint = tint
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

    private var glyph: some View {
        // Minimal translation motif: rounded square outline with divider and “A | 文” pair.
        ZStack {
            RoundedRectangle(cornerRadius: glyphSize * 0.24, style: .continuous)
                .stroke(tint, lineWidth: max(1, glyphSize * 0.06))

            // Divider
            Capsule()
                .fill(tint)
                .frame(width: max(1, glyphSize * 0.06), height: glyphSize * 0.58)

            // A | 文 monogram
            HStack(spacing: glyphSize * 0.14) {
                Text("A")
                    .font(.system(size: glyphSize * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                Text("文")
                    .font(.system(size: glyphSize * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: glyphSize, height: glyphSize)
        .drawingGroup()
    }

    private var wordmark: some View {
        Text("Langscape")
            .font(.system(size: glyphSize * 0.5, weight: .semibold, design: .rounded))
            .kerning(0.5)
            .foregroundStyle(tint)
    }
}
