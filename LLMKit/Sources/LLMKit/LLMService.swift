import Foundation
import Utilities

public protocol LLMServiceProtocol: Sendable {
    func translate(_ text: String, from source: Language, to target: Language) async throws -> String
}

public actor LLMService: LLMServiceProtocol {
    public enum Error: Swift.Error, Equatable {
        case emptyInput
    }

    private struct TranslationKey: Hashable {
        let text: String
        let source: Language
        let target: Language
    }

    private struct FallbackFormatter {
        func translation(for text: String, source: Language, target: Language) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            switch (source, target) {
            case (.english, .spanish):
                return "el/la \(trimmed)"
            case (.spanish, .english):
                let lowered = trimmed
                let articleStripped = Self.stripSpanishArticle(from: lowered)
                return "the \(articleStripped)"
            default:
                return trimmed
            }
        }

        private static func stripSpanishArticle(from text: String) -> String {
            for article in ["el ", "la ", "los ", "las "] {
                if text.hasPrefix(article) {
                    return String(text.dropFirst(article.count))
                }
            }
            return text
        }
    }

    private enum Constants {
        static let modelManifestName = "model-manifest"
        static let modelManifestExtension = "json"
    }

    private let client: any LLMClient
    private let bundle: Bundle
    private let logger: Logger
    private let fallbackFormatter: FallbackFormatter
    private let modelAvailable: Bool
    private var cache: [TranslationKey: String]

    public init(client: any LLMClient = LangscapeLLM(), bundle: Bundle? = nil, logger: Logger = .shared) {
        self.client = client
        let resourceBundle = bundle ?? .module
        self.bundle = resourceBundle
        self.logger = logger
        self.fallbackFormatter = FallbackFormatter()
        self.cache = [:]
        self.modelAvailable = LLMService.hasBundledModel(in: resourceBundle, logger: logger)
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw Error.emptyInput
        }

        guard source != target else {
            return normalized
        }

        let key = TranslationKey(text: normalized.lowercased(), source: source, target: target)
        if let cached = cache[key] {
            Task { await logger.log("Returning cached translation", level: .debug, category: "LLMKit") }
            return cached
        }

        let resolved: String
        if modelAvailable {
            let prompt = LLMService.prompt(for: normalized, source: source, target: target)
            let raw = await client.send(prompt: prompt)
            let candidate = LLMService.extractTranslation(from: raw)
            if let candidate, !candidate.isEmpty {
                resolved = candidate
            } else {
                resolved = fallbackFormatter.translation(for: normalized, source: source, target: target)
            }
        } else {
            resolved = fallbackFormatter.translation(for: normalized, source: source, target: target)
            Task {
                await logger.log(
                    "LLM model missing – using deterministic fallback for translation",
                    level: .warning,
                    category: "LLMKit"
                )
            }
        }

        cache[key] = resolved
        Task { await logger.log("Translated phrase using offline service", level: .info, category: "LLMKit") }
        return resolved
    }

    private static func hasBundledModel(in bundle: Bundle, logger: Logger) -> Bool {
        if bundle.url(forResource: Constants.modelManifestName, withExtension: Constants.modelManifestExtension) != nil {
            return true
        }

        Task {
            await logger.log(
                "Bundled LLM manifest missing. Falling back to deterministic translations.",
                level: .warning,
                category: "LLMKit"
            )
        }
        return false
    }

    private static func prompt(for text: String, source: Language, target: Language) -> String {
        "Translate the noun '\(text)' from \(source.displayName) to \(target.displayName). Respond with only the translated noun and article."
    }

    private static func extractTranslation(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let range = trimmed.range(of: ":") {
            let candidate = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }

        return trimmed
    }
}
