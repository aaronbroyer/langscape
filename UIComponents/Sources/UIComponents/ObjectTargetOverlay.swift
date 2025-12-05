#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics
import DesignSystem

public struct ObjectTargetOverlay: View {
    public enum State: Equatable {
        case pending
        case satisfied
    }

    private let frame: CGRect
    private let state: State

    public init(frame: CGRect, state: State = .pending) {
        self.frame = frame
        self.state = state
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillGradient)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .shadow(color: glowColor.opacity(0.35), radius: 12, x: 0, y: 8)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .animation(.easeInOut(duration: 0.25), value: state)
    }

    private var cornerRadius: CGFloat {
        max(12, min(frame.width, frame.height) * 0.12)
    }

    private var borderWidth: CGFloat { state == .satisfied ? 3 : 2 }

    private var borderColor: Color {
        switch state {
        case .pending:
            return ColorPalette.accent.swiftUIColor.opacity(0.85)
        case .satisfied:
            return ColorPalette.primary.swiftUIColor
        }
    }

    private var glowColor: Color {
        switch state {
        case .pending:
            return ColorPalette.accent.swiftUIColor
        case .satisfied:
            return ColorPalette.primary.swiftUIColor
        }
    }

    private var fillGradient: LinearGradient {
        switch state {
        case .pending:
            return LinearGradient(
                colors: [
                    ColorPalette.accent.swiftUIColor.opacity(0.20),
                    ColorPalette.primary.swiftUIColor.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .satisfied:
            return LinearGradient(
                colors: [
                    ColorPalette.primary.swiftUIColor.opacity(0.30),
                    ColorPalette.primary.swiftUIColor.opacity(0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#Preview {
    ZStack {
        Color.black
        ObjectTargetOverlay(frame: CGRect(x: 120, y: 200, width: 160, height: 120))
        ObjectTargetOverlay(frame: CGRect(x: 40, y: 80, width: 80, height: 80), state: .satisfied)
    }
    .frame(width: 320, height: 480)
}
#endif
