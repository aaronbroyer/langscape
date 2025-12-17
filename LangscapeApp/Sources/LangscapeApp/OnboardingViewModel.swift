import Foundation
import Utilities
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable {
        case splash
        case hero
        case languageSelection
        case cameraPermission
        case done
    }

    @Published var step: Step = .splash

    enum Language: String, CaseIterable, Identifiable, Equatable {
        case english
        case spanish

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .english:
                return "English"
            case .spanish:
                return "Spanish"
            }
        }

        var flag: String {
            switch self {
            case .english:
                return "🇺🇸"
            case .spanish:
                return "🇪🇸"
            }
        }

        var opposite: Language {
            switch self {
            case .english:
                return .spanish
            case .spanish:
                return .english
            }
        }
    }

    @Published var targetLanguage: Language
    @Published var nativeLanguage: Language

    private let settings: AppSettings
    private var hasScheduledSplashAdvance = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        let languagePair = Self.languages(from: settings.selectedLanguage)
        targetLanguage = languagePair.target
        nativeLanguage = languagePair.native
        if settings.hasCompletedOnboarding {
            step = .done
        }
    }

    func advanceFromSplash() {
        guard step == .splash else { return }
        step = .hero
    }

    func scheduleAutomaticSplashAdvance() {
        guard step == .splash, !hasScheduledSplashAdvance else { return }
        hasScheduledSplashAdvance = true

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            advanceFromSplash()
        }
    }

    func getStartedFromHero() {
        guard step == .hero else { return }
        step = .languageSelection
    }

    func setTargetLanguage(_ language: Language) {
        targetLanguage = language
        nativeLanguage = language.opposite
    }

    func setNativeLanguage(_ language: Language) {
        nativeLanguage = language
        targetLanguage = language.opposite
    }

    func continueFromLanguageSelection() {
        guard step == .languageSelection else { return }
        settings.selectedLanguage = Self.preference(target: targetLanguage, native: nativeLanguage)
        step = .cameraPermission
    }

    func skipLanguageSelection() {
        guard step == .languageSelection else { return }
        let languagePair = Self.languages(from: settings.selectedLanguage)
        targetLanguage = languagePair.target
        nativeLanguage = languagePair.native
        step = .cameraPermission
    }

    func requestCameraAccess() async {
        #if canImport(AVFoundation)
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch currentStatus {
        case .authorized:
            return
        case .notDetermined:
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    continuation.resume(returning: ())
                }
            }
        default:
            return
        }
        #endif
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        step = .done
    }

    func resetFlow() {
        hasScheduledSplashAdvance = false
        step = .splash

        let languagePair = Self.languages(from: settings.selectedLanguage)
        targetLanguage = languagePair.target
        nativeLanguage = languagePair.native
    }

    private static func languages(from preference: LanguagePreference) -> (target: Language, native: Language) {
        switch preference {
        case .englishToSpanish:
            return (target: .spanish, native: .english)
        case .spanishToEnglish:
            return (target: .english, native: .spanish)
        }
    }

    private static func preference(target: Language, native: Language) -> LanguagePreference {
        switch (target, native) {
        case (.spanish, .english):
            return .englishToSpanish
        case (.english, .spanish):
            return .spanishToEnglish
        default:
            // Default to a supported pair if a caller sets an invalid combination.
            return .englishToSpanish
        }
    }
}
