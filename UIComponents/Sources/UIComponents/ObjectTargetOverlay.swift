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
            .strokeBorder(borderColor, lineWidth: borderWidth)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
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
            return ColorPalette.secondary.swiftUIColor.opacity(0.75)
        case .satisfied:
            return ColorPalette.primary.swiftUIColor
        }
    }

    private var fillColor: Color {
        switch state {
        case .pending:
            return Color.black.opacity(0.12)
        case .satisfied:
            return ColorPalette.primary.swiftUIColor.opacity(0.25)
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
