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
        GeometryReader { proxy in
            let horizontalInset = Spacing.large.cgFloat
            let panelWidth = max(proxy.size.width - (horizontalInset * 2), 0)
            let contentWidth = max(panelWidth - (Spacing.medium.cgFloat * 2), 0)

            TranslucentPanel(cornerRadius: 24) {
                VStack(spacing: Spacing.small.cgFloat) {
                    Text("Paused")
                        .font(Typography.title.font.weight(.semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)

                    PrimaryButton(title: "Resume", size: .compact, action: resumeAction)

                    Button(role: .destructive, action: exitAction) {
                        Text("Return Home")
                            .font(Typography.body.font)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(ColorPalette.accent.swiftUIColor)
                }
                .frame(width: contentWidth)
                .padding(.vertical, Spacing.small.cgFloat)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

#Preview {
    ZStack {
        ColorPalette.background.swiftUIColor
        PauseOverlay(resumeAction: {}, exitAction: {})
    }
}
#endif
