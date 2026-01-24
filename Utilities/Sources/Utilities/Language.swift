import Foundation

public enum Language: String, Codable, CaseIterable, Sendable {
    case english
    case spanish
    case french

    public var displayName: String {
        switch self {
        case .english:
            return "English"
        case .spanish:
            return "Spanish"
        case .french:
            return "French"
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
        case .englishToFrench:
            return .english
        case .frenchToEnglish:
            return .french
        case .spanishToFrench:
            return .spanish
        case .frenchToSpanish:
            return .french
        }
    }

    var targetLanguage: Language {
        switch self {
        case .englishToSpanish:
            return .spanish
        case .spanishToEnglish:
            return .english
        case .englishToFrench:
            return .french
        case .frenchToEnglish:
            return .english
        case .spanishToFrench:
            return .french
        case .frenchToSpanish:
            return .spanish
        }
    }
}
