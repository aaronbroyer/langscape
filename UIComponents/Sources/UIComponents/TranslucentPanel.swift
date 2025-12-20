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
            .background(panelBackground)
            .overlay(panelBorder)
            .shadow(color: Color.black.opacity(0.16), radius: 14, x: 0, y: 10)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var panelBackground: some View {
        panelShape
            .fill(.ultraThinMaterial)
            .overlay(
                panelShape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.05),
                            Color.black.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
    }

    private var panelBorder: some View {
        panelShape
            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            .overlay(
                panelShape
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
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
