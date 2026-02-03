#if canImport(SwiftUI)
import SwiftUI
import DesignSystem
import Utilities

public struct PrimaryButton: View {
    public enum Size {
        case regular
        case compact
    }

    private let title: String
    private let action: () -> Void
    private let logger: Logger
    private let size: Size

    public init(title: String, size: Size = .regular, logger: Logger = .shared, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.logger = logger
        self.size = size
    }

    public var body: some View {
        Button(action: handleTap) {
            Text(title)
                .font(Typography.body.font)
                .padding(.vertical, size == .compact ? Spacing.xSmall.cgFloat : Spacing.small.cgFloat)
                .padding(.horizontal, Spacing.medium.cgFloat)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(ColorPalette.primary.swiftUIColor)
    }

    private func handleTap() {
        Task {
            await logger.log("PrimaryButton tapped", level: .debug, category: "UIComponents")
            action()
        }
    }
}

#Preview {
    PrimaryButton(title: "Continue") {}
        .padding(Spacing.large.cgFloat)
        .previewLayout(.sizeThatFits)
}
#endif
