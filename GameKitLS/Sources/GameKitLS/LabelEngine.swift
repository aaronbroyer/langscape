import Foundation
import Utilities
import VocabStore
import LLMKit

public protocol LabelProviding: Sendable {
    func makeLabels(for objects: [DetectedObject], preference: LanguagePreference) async -> [Label]
}

public actor LabelEngine: LabelProviding {
    private struct CacheKey: Hashable {
        let className: String
        let preference: LanguagePreference
    }

    private let vocabularyStore: VocabularyStore
    private let llmService: any LLMServiceProtocol
    private let logger: Logger
    private var cache: [CacheKey: String]

    public init(
        vocabularyStore: VocabularyStore = VocabularyStore(),
        llmService: any LLMServiceProtocol = LLMService(),
        logger: Logger = .shared
    ) {
        self.vocabularyStore = vocabularyStore
        self.llmService = llmService
        self.logger = logger
        self.cache = [:]
    }

    public func makeLabels(for objects: [DetectedObject], preference: LanguagePreference) async -> [Label] {
        var labels: [Label] = []
        labels.reserveCapacity(objects.count)

        for object in objects {
            let text = await translation(for: object.sourceLabel, preference: preference)
            labels.append(Label(text: text, sourceLabel: object.sourceLabel, objectID: object.id))
        }

        return labels
    }

    public func translation(for className: String, preference: LanguagePreference) async -> String {
        let key = CacheKey(className: className.normalizedKey(), preference: preference)
        if let cached = cache[key] {
            return cached
        }

        if let direct = await vocabularyStore.translation(for: className, preference: preference) {
            cache[key] = direct
            Task { await logger.log("Vocab hit for \(className) -> \(direct)", level: .debug, category: "GameKitLS.LabelEngine") }
            return direct
        }

        let sourceLanguage = preference.sourceLanguage
        let targetLanguage = preference.targetLanguage
        let sourceText: String
        let effectiveSource: Language

        if sourceLanguage == .english {
            sourceText = className
            effectiveSource = .english
        } else if let entry = await vocabularyStore.entry(for: className),
                  let localized = entry.text(for: sourceLanguage) {
            sourceText = localized
            effectiveSource = sourceLanguage
        } else {
            sourceText = className
            effectiveSource = .english
        }

        do {
            let translated = try await llmService.translate(sourceText, from: effectiveSource, to: targetLanguage)
            cache[key] = translated
            Task { await logger.log("LLM translated \(sourceText) (\(effectiveSource.rawValue)->\(targetLanguage.rawValue)) -> \(translated)", level: .debug, category: "GameKitLS.LabelEngine") }
            return translated
        } catch {
            let fallback = sourceText
            cache[key] = fallback
            Task {
                await logger.log(
                    "Translation unavailable for \(className): \(error.localizedDescription)",
                    level: .warning,
                    category: "GameKitLS.LabelEngine"
                )
            }
            return fallback
        }
    }
}

private extension String {
    func normalizedKey() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
