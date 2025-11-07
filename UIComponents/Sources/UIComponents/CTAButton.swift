#if canImport(SwiftUI)
import SwiftUI
import DesignSystem
import Utilities

public struct CTAButton: View {
    private let title: String
    private let systemImage: String?
    private let action: () -> Void
    private let logger: Logger

    public init(_ title: String, systemImage: String? = nil, logger: Logger = .shared, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
        self.logger = logger
    }

    public var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 16, weight: .semibold)) }
                Text(title)
                    .font(Typography.body.font.weight(.semibold))
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.vertical, Spacing.small.cgFloat * 1.25)
            .background(
                Capsule(style: .circular)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .circular)
                    .stroke(ColorPalette.primary.swiftUIColor.opacity(0.35), lineWidth: 1)
            )
            .foregroundStyle(ColorPalette.primary.swiftUIColor)
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func handleTap() {
        Task { await logger.log("CTAButton tapped", level: .debug, category: "UIComponents") }
        action()
    }
}

#Preview {
    VStack(spacing: 16) {
        CTAButton("Get Started", systemImage: "viewfinder") {}
        CTAButton("Choose Language", systemImage: "character.book.closed") {}
    }
    .padding()
    .background(Color.black.opacity(0.9))
}
#endif

