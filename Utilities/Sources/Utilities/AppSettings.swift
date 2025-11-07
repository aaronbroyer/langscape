import Foundation
import Combine

public enum LanguagePreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case englishToSpanish
    case spanishToEnglish

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .englishToSpanish:
            return "English → Spanish"
        case .spanishToEnglish:
            return "Spanish → English"
        }
    }

    public var detail: String {
        switch self {
        case .englishToSpanish:
            return "Learn Spanish names for what you discover."
        case .spanishToEnglish:
            return "Translate familiar Spanish words into English."
        }
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    private enum Keys {
        static let selectedLanguage = "app.selectedLanguage"
        static let completedOnboarding = "app.completedOnboarding"
    }

    public static let shared = AppSettings()

    @Published public var selectedLanguage: LanguagePreference {
        didSet { persistLanguage(selectedLanguage) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { persistOnboardingFlag(hasCompletedOnboarding) }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if
            let storedValue = userDefaults.string(forKey: Keys.selectedLanguage),
            let storedPreference = LanguagePreference(rawValue: storedValue)
        {
            selectedLanguage = storedPreference
        } else {
            selectedLanguage = .englishToSpanish
        }

        if userDefaults.object(forKey: Keys.completedOnboarding) != nil {
            hasCompletedOnboarding = userDefaults.bool(forKey: Keys.completedOnboarding)
        } else {
            hasCompletedOnboarding = false
        }
    }

    public func reset() {
        selectedLanguage = .englishToSpanish
        hasCompletedOnboarding = false
    }

    private func persistLanguage(_ preference: LanguagePreference) {
        userDefaults.set(preference.rawValue, forKey: Keys.selectedLanguage)
    }

    private func persistOnboardingFlag(_ flag: Bool) {
        userDefaults.set(flag, forKey: Keys.completedOnboarding)
    }
}
