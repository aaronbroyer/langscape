#if canImport(SwiftUI)
import SwiftUI
import DesignSystem

public struct LabelToken: View {
    public enum VisualState: Equatable {
        case idle
        case incorrect
        case placed
    }

    private let text: String
    private let state: VisualState

    public init(text: String, state: VisualState = .idle) {
        self.text = text
        self.state = state
    }

    public var body: some View {
        Text(text)
            .font(Typography.body.font.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.vertical, Spacing.small.cgFloat)
            .background(background)
            .overlay(border)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 6)
            .opacity(state == .placed ? 0.12 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: state)
    }

    private var background: some View {
        Capsule()
            .fill(backgroundColor)
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.05),
                                Color.black.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }

    private var border: some View {
        Capsule()
            .strokeBorder(borderColor, lineWidth: 1)
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    private var backgroundColor: Color {
        switch state {
        case .idle:
            return ColorPalette.surface.swiftUIColor.opacity(0.82)
        case .incorrect:
            return ColorPalette.accent.swiftUIColor.opacity(0.88)
        case .placed:
            return ColorPalette.primary.swiftUIColor.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch state {
        case .idle:
            return Color.white.opacity(0.32)
        case .incorrect:
            return Color.white.opacity(0.6)
        case .placed:
            return ColorPalette.primary.swiftUIColor.opacity(0.3)
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .idle:
            return ColorPalette.primary.swiftUIColor
        case .incorrect:
            return Color.white
        case .placed:
            return ColorPalette.primary.swiftUIColor.opacity(0.75)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        LabelToken(text: "la taza")
        LabelToken(text: "la silla", state: .incorrect)
        LabelToken(text: "el libro", state: .placed)
    }
    .padding()
    .background(ColorPalette.background.swiftUIColor)
}
#endif
