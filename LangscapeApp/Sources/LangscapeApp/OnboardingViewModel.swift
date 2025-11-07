import Foundation
import Utilities

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable {
        case splash
        case slides
        case languageSelection
        case cameraPermission
        case done
    }

    @Published var step: Step = .splash

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        if settings.hasCompletedOnboarding {
            step = .done
        }
    }

    func advanceFromSplash() {
        guard step == .splash else { return }
        step = .slides
    }

    func showLanguageSelection() {
        guard step == .slides || step == .splash else { return }
        step = .languageSelection
    }

    func selectLanguage(_ preference: LanguagePreference) {
        settings.selectedLanguage = preference
        step = .cameraPermission
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        step = .done
    }
}

