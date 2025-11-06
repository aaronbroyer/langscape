import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum ColorPalette {
    public static let primary = DSColor(light: "#1D3557", dark: "#A8DADC")
    public static let secondary = DSColor(light: "#457B9D", dark: "#457B9D")
    public static let accent = DSColor(light: "#E63946", dark: "#E63946")
    public static let background = DSColor(light: "#F1FAEE", dark: "#1D3557")
    public static let surface = DSColor(light: "#FFFFFF", dark: "#2C3E50")
}

public struct DSColor: Equatable, Sendable {
    public let light: String
    public let dark: String

    public init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    #if canImport(SwiftUI)
    public var swiftUIColor: Color {
        Color(lightHex: light, darkHex: dark)
    }
    #endif
}

#if canImport(SwiftUI) && canImport(UIKit)
private extension Color {
    init(lightHex: String, darkHex: String) {
        if UITraitCollection.current.userInterfaceStyle == .dark {
            self.init(hex: darkHex)
        } else {
            self.init(hex: lightHex)
        }
    }

    init(hex: String) {
        let scanner = Scanner(string: hex)
        _ = scanner.scanString("#")

        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
#endif
