#if canImport(SwiftUI)
import SwiftUI
import Utilities

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable {
        case splash
        case slides
        case languageSelection
        case cameraPermission
    }

    struct Slide: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        let systemImageName: String
    }

    @Published private(set) var step: Step
    let slides: [Slide]

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.step = settings.hasCompletedOnboarding ? .cameraPermission : .splash
        self.slides = [
            Slide(
                title: "Discover the world through language.",
                subtitle: "Meet everyday objects with fresh vocabulary as you explore.",
                systemImageName: "globe.europe.africa"
            ),
            Slide(
                title: "Point your camera and learn real words in real places.",
                subtitle: "Langscape works entirely offline so you can learn anywhere.",
                systemImageName: "camera.fill"
            ),
            Slide(
                title: "Drag words to objects to master vocabulary in context.",
                subtitle: "Match labels to what you see for instant feedback.",
                systemImageName: "hand.draw"
            )
        ]
    }

    func advanceFromSplash() {
        guard step == .splash else { return }
        withAnimation { step = .slides }
    }

    func showLanguageSelection() {
        guard step == .slides else { return }
        withAnimation { step = .languageSelection }
    }

    func selectLanguage(_ preference: LanguagePreference) {
        settings.selectedLanguage = preference
        withAnimation { step = .cameraPermission }
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
    }
}
#endif
