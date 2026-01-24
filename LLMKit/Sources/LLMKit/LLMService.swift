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
        case localModelUnavailable
        case translationFailed
    }

    private struct TranslationKey: Hashable {
        let text: String
        let source: Language
        let target: Language
    }

    private struct TranslationPair: Hashable {
        let source: Language
        let target: Language
    }

    public enum TranslationPolicy: Sendable {
        case localOnly
        case localThenRemote
        case remoteThenLocal
    }

    private struct ManifestEntry: Decodable {
        let type: String?
        let source: Language
        let target: Language

        let modelFile: String?
        let inputFeature: String?
        let outputFeature: String?

        let encoderModel: String?
        let decoderModel: String?
        let sourceTokenizer: String?
        let targetTokenizer: String?
        let vocabFile: String?
        let maxInputTokens: Int?
        let maxOutputTokens: Int?
        let decoderStartTokenId: Int?
        let eosTokenId: Int?
        let padTokenId: Int?
    }

    private struct ManifestContainer: Decodable {
        let models: [ManifestEntry]
    }

    private let client: any LLMClient
    private let bundle: Bundle
    private let logger: Logger
    private let translationPolicy: TranslationPolicy
    private var cache: [TranslationKey: String]
    private var translators: [TranslationPair: any TranslationProviding]

    public init(
        client: any LLMClient = LangscapeLLM(),
        bundle: Bundle? = nil,
        logger: Logger = .shared,
        translationPolicy: TranslationPolicy = .localOnly
    ) {
        self.client = client
        let resourceBundle = bundle ?? .module
        self.bundle = resourceBundle
        self.logger = logger
        self.translationPolicy = translationPolicy
        self.cache = [:]
        self.translators = LLMService.loadTranslators(from: resourceBundle, logger: logger)
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

        let pair = TranslationPair(source: source, target: target)

        switch translationPolicy {
        case .localOnly:
            if let localTranslation = await requestLocalTranslation(for: normalized, pair: pair) {
                cache[key] = localTranslation
                Task { await logger.log("Translated phrase using CoreML", level: .info, category: "LLMKit") }
                return localTranslation
            }
            throw Error.localModelUnavailable
        case .localThenRemote:
            if let localTranslation = await requestLocalTranslation(for: normalized, pair: pair) {
                cache[key] = localTranslation
                Task { await logger.log("Translated phrase using CoreML", level: .info, category: "LLMKit") }
                return localTranslation
            }
            if let remoteTranslation = await requestLLMTranslation(for: normalized, source: source, target: target) {
                cache[key] = remoteTranslation
                Task { await logger.log("Translated phrase using LLM", level: .info, category: "LLMKit") }
                return remoteTranslation
            }
            throw Error.translationFailed
        case .remoteThenLocal:
            if let remoteTranslation = await requestLLMTranslation(for: normalized, source: source, target: target) {
                cache[key] = remoteTranslation
                Task { await logger.log("Translated phrase using LLM", level: .info, category: "LLMKit") }
                return remoteTranslation
            }
            if let localTranslation = await requestLocalTranslation(for: normalized, pair: pair) {
                cache[key] = localTranslation
                Task { await logger.log("Translated phrase using CoreML", level: .info, category: "LLMKit") }
                return localTranslation
            }
            throw Error.translationFailed
        }
    }

    private func requestLocalTranslation(for text: String, pair: TranslationPair) async -> String? {
        guard let translator = translators[pair] else {
            Task { await logger.log("No local translation model for \(pair.source.rawValue)->\(pair.target.rawValue)", level: .debug, category: "LLMKit") }
            return nil
        }
        do {
            return try await translator.translate(text, from: pair.source, to: pair.target)
        } catch {
            Task { await logger.log("CoreML translator failed: \(error.localizedDescription)", level: .error, category: "LLMKit") }
            return nil
        }
    }
    private func requestLLMTranslation(for text: String, source: Language, target: Language) async -> String? {
        let promptText = Self.prompt(for: text, source: source, target: target)
        do {
            let response = try await client.send(prompt: promptText)
            if let extracted = Self.extractTranslation(from: response) {
                return extracted
            }
            Task { await logger.log("LLM returned an empty translation", level: .warning, category: "LLMKit") }
        } catch {
            Task { await logger.log("LLM translation failed: \(error.localizedDescription)", level: .error, category: "LLMKit") }
        }
        return nil
    }

    private static func loadTranslators(from bundle: Bundle, logger: Logger) -> [TranslationPair: any TranslationProviding] {
        #if canImport(CoreML)
        guard let manifestURL = bundle.url(forResource: "model-manifest", withExtension: "json") else {
            Task { await logger.log("No translation manifest found", level: .debug, category: "LLMKit") }
            return [:]
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            let manifests: [ManifestEntry]
            if let container = try? decoder.decode(ManifestContainer.self, from: data) {
                manifests = container.models
            } else if let array = try? decoder.decode([ManifestEntry].self, from: data) {
                manifests = array
            } else {
                manifests = [try decoder.decode(ManifestEntry.self, from: data)]
            }

            var results: [TranslationPair: any TranslationProviding] = [:]
            for manifest in manifests {
                let pair = TranslationPair(source: manifest.source, target: manifest.target)
                do {
                    if manifest.type == "marian" || manifest.encoderModel != nil {
                        let config = MarianTranslator.Config(
                            maxInputTokens: manifest.maxInputTokens ?? 32,
                            maxOutputTokens: manifest.maxOutputTokens ?? 32,
                            decoderStartTokenId: manifest.decoderStartTokenId ?? 65000,
                            eosTokenId: manifest.eosTokenId ?? 0,
                            padTokenId: manifest.padTokenId ?? 65000
                        )

                        guard
                            let encoderModel = manifest.encoderModel,
                            let decoderModel = manifest.decoderModel,
                            let sourceTokenizer = manifest.sourceTokenizer,
                            let targetTokenizer = manifest.targetTokenizer,
                            let vocabFile = manifest.vocabFile
                        else {
                            Task { await logger.log("Marian manifest missing required fields for \(pair.source.rawValue)->\(pair.target.rawValue).", level: .error, category: "LLMKit") }
                            continue
                        }

                        let translator = try MarianTranslator(
                            bundle: bundle,
                            encoderModel: encoderModel,
                            decoderModel: decoderModel,
                            sourceTokenizer: sourceTokenizer,
                            targetTokenizer: targetTokenizer,
                            vocabFile: vocabFile,
                            source: manifest.source,
                            target: manifest.target,
                            config: config,
                            logger: logger
                        )
                        results[pair] = translator
                    } else if let modelFile = manifest.modelFile,
                              let inputFeature = manifest.inputFeature,
                              let outputFeature = manifest.outputFeature {
                        let json: [String: Any] = [
                            "modelFile": modelFile,
                            "inputFeature": inputFeature,
                            "outputFeature": outputFeature,
                            "source": manifest.source.rawValue,
                            "target": manifest.target.rawValue
                        ]
                        let translator = try CoreMLTranslator(bundle: bundle, manifest: json, logger: logger)
                        results[pair] = translator
                    } else {
                        Task { await logger.log("Manifest entry missing model info for \(pair.source.rawValue)->\(pair.target.rawValue).", level: .error, category: "LLMKit") }
                    }
                } catch {
                    Task { await logger.log("Failed to load translator: \(error)", level: .error, category: "LLMKit") }
                }
            }

            return results
        } catch {
            Task { await logger.log("Failed to load translator manifest: \(error.localizedDescription)", level: .error, category: "LLMKit") }
            return [:]
        }
        #else
        return [:]
        #endif
    }

    private static func prompt(for text: String, source: Language, target: Language) -> String {
        "Translate the noun '\(text)' from \(source.displayName) to \(target.displayName). Return only the translated noun with the correct article, no extra words or punctuation."
    }

    private static func extractTranslation(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        var candidate = firstLine

        if let range = candidate.range(of: ":") {
            candidate = String(candidate[range.upperBound...])
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        if candidate.count >= 2 {
            if (candidate.hasPrefix("\"") && candidate.hasSuffix("\"")) || (candidate.hasPrefix("'") && candidate.hasSuffix("'")) {
                candidate = String(candidate.dropFirst().dropLast())
            }
            if candidate.hasPrefix("`") && candidate.hasSuffix("`") {
                candidate = String(candidate.dropFirst().dropLast())
            }
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}
