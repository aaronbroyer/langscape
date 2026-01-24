import Foundation
import Utilities
import LLMKit

public protocol LabelProviding: Sendable {
    func makeLabels(for objects: [DetectedObject], preference: LanguagePreference) async -> [Label]
}

public actor LabelEngine: LabelProviding {
    private struct CacheKey: Hashable {
        let className: String
        let preference: LanguagePreference
    }

    private let llmService: any LLMServiceProtocol
    private let logger: Logger
    private var cache: [CacheKey: String]

    public init(
        llmService: any LLMServiceProtocol = LLMService(),
        logger: Logger = .shared
    ) {
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

        let targetLanguage = preference.targetLanguage
        let sourceText = className
        let effectiveSource: Language = .english

        if targetLanguage == .english {
            cache[key] = sourceText
            return sourceText
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
