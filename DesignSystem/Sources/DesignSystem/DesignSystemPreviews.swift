#if canImport(SwiftUI)
import SwiftUI

public struct DesignSystemPreview: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium.cgFloat) {
            Text("Langscape Design System")
                .font(Typography.largeTitle.font)
                .foregroundStyle(ColorPalette.primary.swiftUIColor)

            VStack(alignment: .leading, spacing: Spacing.small.cgFloat) {
                swatch(title: "Primary", color: ColorPalette.primary.swiftUIColor)
                swatch(title: "Secondary", color: ColorPalette.secondary.swiftUIColor)
                swatch(title: "Accent", color: ColorPalette.accent.swiftUIColor)
            }
            .padding(Spacing.small.cgFloat)
            .background(ColorPalette.surface.swiftUIColor)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.small.cgFloat))
        }
        .padding(Spacing.large.cgFloat)
        .background(ColorPalette.background.swiftUIColor)
    }

    private func swatch(title: String, color: Color) -> some View {
        Text(title)
            .font(Typography.body.font)
            .padding(Spacing.small.cgFloat)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.xSmall.cgFloat))
    }
}

#Preview {
    DesignSystemPreview()
        .previewLayout(.sizeThatFits)
        .padding()
}
#endif
