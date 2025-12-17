#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public struct OnboardingHeroRoomBackdrop: View {
    public init() {}

    public var body: some View {
        #if canImport(UIKit)
        if let uiImage = Self.uiImage {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            Color.black.accessibilityHidden(true)
        }
        #else
        Color.black.accessibilityHidden(true)
        #endif
    }

    #if canImport(UIKit)
    private static let uiImage: UIImage? = {
        guard let url = Bundle.module.url(forResource: "OnboardingHeroRoom", withExtension: "jpg") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }()
    #endif
}
#endif
