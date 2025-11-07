#if canImport(SwiftUI)
import SwiftUI
import DesignSystem

public struct PauseOverlay: View {
    private let resumeAction: () -> Void
    private let exitAction: () -> Void

    public init(resumeAction: @escaping () -> Void, exitAction: @escaping () -> Void) {
        self.resumeAction = resumeAction
        self.exitAction = exitAction
    }

    public var body: some View {
        TranslucentPanel(cornerRadius: 24) {
            VStack(spacing: Spacing.medium.cgFloat) {
                Text("Paused")
                    .font(Typography.title.font.weight(.semibold))
                    .foregroundStyle(ColorPalette.primary.swiftUIColor)

                PrimaryButton(title: "Resume", action: resumeAction)

                Button(role: .destructive, action: exitAction) {
                    Text("Return Home")
                        .font(Typography.body.font)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(ColorPalette.accent.swiftUIColor)
            }
            .padding(.vertical, Spacing.medium.cgFloat)
        }
        .padding(.horizontal, Spacing.large.cgFloat)
    }
}

#Preview {
    ZStack {
        ColorPalette.background.swiftUIColor
        PauseOverlay(resumeAction: {}, exitAction: {})
    }
}
#endif
