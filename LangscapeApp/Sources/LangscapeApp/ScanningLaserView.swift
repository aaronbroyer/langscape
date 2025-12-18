#if canImport(SwiftUI)
import SwiftUI
import DesignSystem

struct ScanningLaserView: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let y = max(0, min(height, height * progress))

            ZStack(alignment: .top) {
                Color.black.opacity(0.06)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(laserGradient)
                    .frame(height: 3)
                    .shadow(color: ColorPalette.accent.swiftUIColor.opacity(0.9), radius: 18, x: 0, y: 0)
                    .overlay(
                        Rectangle()
                            .fill(ColorPalette.accent.swiftUIColor.opacity(0.35))
                            .blur(radius: 10)
                            .frame(height: 14)
                    )
                    .position(x: proxy.size.width / 2, y: y)
            }
            .onAppear {
                progress = 0
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    progress = 1
                }
            }
        }
    }

    private var laserGradient: LinearGradient {
        LinearGradient(
            colors: [
                ColorPalette.accent.swiftUIColor.opacity(0.0),
                ColorPalette.accent.swiftUIColor.opacity(0.9),
                ColorPalette.accent.swiftUIColor.opacity(0.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
#endif

