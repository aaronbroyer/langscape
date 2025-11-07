import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public enum Typography {
    public static let largeTitle = FontDescriptor(size: 34, lineHeight: 41, weight: .bold)
    public static let title = FontDescriptor(size: 28, lineHeight: 34, weight: .semibold)
    public static let body = FontDescriptor(size: 17, lineHeight: 24, weight: .regular)
    public static let caption = FontDescriptor(size: 13, lineHeight: 18, weight: .regular)
}

public struct FontDescriptor: Equatable, Sendable {
    public enum Weight: String, Sendable {
        case regular
        case medium
        case semibold
        case bold
    }

    public let size: CGFloatValue
    public let lineHeight: CGFloatValue
    public let weight: Weight

    public init(size: CGFloatValue, lineHeight: CGFloatValue, weight: Weight) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
    }
}

public struct CGFloatValue: Equatable, Sendable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public let rawValue: Double

    public init(_ rawValue: Double) {
        self.rawValue = rawValue
    }

    // Allow numeric literals (e.g., 34, 17.0) where CGFloatValue is expected
    public init(integerLiteral value: IntegerLiteralType) {
        self.rawValue = Double(value)
    }

    public init(floatLiteral value: FloatLiteralType) {
        self.rawValue = value
    }
}

#if canImport(SwiftUI)
public extension FontDescriptor {
    var font: Font {
        Font.system(size: CGFloat(size.rawValue), weight: weight.fontWeight)
    }
}

private extension FontDescriptor.Weight {
    var fontWeight: Font.Weight {
        switch self {
        case .regular:
            return .regular
        case .medium:
            return .medium
        case .semibold:
            return .semibold
        case .bold:
            return .bold
        }
    }
}
#endif
