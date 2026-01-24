import Utilities

public protocol TranslationProviding: Sendable {
    func supports(source: Language, target: Language) -> Bool
    func translate(_ text: String, from source: Language, to target: Language) async throws -> String
}
