#if canImport(SwiftUI)
import SwiftUI
import DesignSystem

public struct TranslucentPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, Spacing.medium.cgFloat)
            .padding(.vertical, Spacing.small.cgFloat)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ColorPalette.surface.swiftUIColor.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 8)
    }
}

#Preview {
    TranslucentPanel {
        Text("Label Scramble")
            .font(Typography.title.font)
    }
    .padding()
    .background(ColorPalette.background.swiftUIColor)
}
#endif
