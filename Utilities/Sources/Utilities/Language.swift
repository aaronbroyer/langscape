import Foundation

public enum Language: String, Codable, CaseIterable, Sendable {
    case english
    case spanish

    public var displayName: String {
        switch self {
        case .english:
            return "English"
        case .spanish:
            return "Spanish"
        }
    }
}

public extension LanguagePreference {
    var sourceLanguage: Language {
        switch self {
        case .englishToSpanish:
            return .english
        case .spanishToEnglish:
            return .spanish
        }
    }

    var targetLanguage: Language {
        switch self {
        case .englishToSpanish:
            return .spanish
        case .spanishToEnglish:
            return .english
        }
    }
}
