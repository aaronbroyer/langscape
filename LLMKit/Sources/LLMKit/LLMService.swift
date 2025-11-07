import Foundation
import Utilities
#if canImport(CoreML)
import CoreML
#endif

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

    // Manifest describes a bundled CoreML translation model, if present.
    private struct Manifest: Decodable {
        let modelFile: String
        let inputFeature: String
        let outputFeature: String
        let source: Language
        let target: Language
    }

    private let client: any LLMClient
    private let bundle: Bundle
    private let logger: Logger
    private let fallbackFormatter: FallbackFormatter
    private var cache: [TranslationKey: String]
    private var translator: CoreMLTranslator?

    public init(client: any LLMClient = LangscapeLLM(), bundle: Bundle? = nil, logger: Logger = .shared) {
        self.client = client
        let resourceBundle = bundle ?? .module
        self.bundle = resourceBundle
        self.logger = logger
        self.fallbackFormatter = FallbackFormatter()
        self.cache = [:]
        self.translator = LLMService.loadTranslator(from: resourceBundle, logger: logger)
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
        if let translator, translator.supports(source: source, target: target) {
            do {
                resolved = try await translator.translate(normalized, from: source, to: target)
            } catch {
                Task { await logger.log("CoreML translator failed: \(error.localizedDescription). Falling back.", level: .error, category: "LLMKit") }
                resolved = fallbackFormatter.translation(for: normalized, source: source, target: target)
            }
        } else {
            resolved = fallbackFormatter.translation(for: normalized, source: source, target: target)
            Task { await logger.log("No local translation model – using deterministic fallback", level: .warning, category: "LLMKit") }
        }

        cache[key] = resolved
        Task { await logger.log("Translated phrase using offline service", level: .info, category: "LLMKit") }
        return resolved
    }

    private static func loadTranslator(from bundle: Bundle, logger: Logger) -> CoreMLTranslator? {
        #if canImport(CoreML)
        guard let manifestURL = bundle.url(forResource: "model-manifest", withExtension: "json") else {
            Task { await logger.log("No translation manifest found", level: .debug, category: "LLMKit") }
            return nil
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            return try CoreMLTranslator(bundle: bundle, manifest: manifest, logger: logger)
        } catch {
            Task { await logger.log("Failed to load translator manifest: \(error.localizedDescription)", level: .error, category: "LLMKit") }
            return nil
        }
        #else
        return nil
        #endif
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
