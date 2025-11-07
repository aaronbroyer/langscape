import Foundation
import Utilities
#if canImport(CoreML)
import CoreML
#endif

public typealias Language = Utilities.Language

#if canImport(CoreML)
public struct CoreMLTranslator {
    public enum Error: Swift.Error { case modelNotFound, predictionFailed(String) }

    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let supportedPair: (source: Language, target: Language)
    private let logger: Logger

    public init(bundle: Bundle, manifest: Any, logger: Logger) throws {
        // Manifest is LLMService.Manifest; we reflect minimally to keep files decoupled.
        struct ManifestShim: Decodable { let modelFile: String; let inputFeature: String; let outputFeature: String; let source: Language; let target: Language }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        let decoded = try JSONDecoder().decode(ManifestShim.self, from: data)
        self.inputName = decoded.inputFeature
        self.outputName = decoded.outputFeature
        self.supportedPair = (decoded.source, decoded.target)
        self.logger = logger

        guard let modelURL = bundle.url(forResource: decoded.modelFile, withExtension: nil) ??
                bundle.url(forResource: (decoded.modelFile as NSString).deletingPathExtension, withExtension: (decoded.modelFile as NSString).pathExtension.isEmpty ? "mlmodelc" : ((decoded.modelFile as NSString).pathExtension)) else {
            throw Error.modelNotFound
        }

        // Expect a compiled model (.mlmodelc or .mlpackage). If a raw .mlmodel is provided,
        // require the build step to compile it to avoid async compile in initialiser.
        guard modelURL.pathExtension != "mlmodel" else { throw Error.modelNotFound }
        self.model = try MLModel(contentsOf: modelURL)
    }

    public func supports(source: Language, target: Language) -> Bool {
        source == supportedPair.source && target == supportedPair.target
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: text])
        let out: MLFeatureProvider
        do {
            if #available(iOS 18.0, macOS 15.0, *) {
                out = try await model.prediction(from: provider)
            } else {
                out = try model.prediction(from: provider)
            }
        } catch {
            throw Error.predictionFailed(error.localizedDescription)
        }
        guard let result = out.featureValue(for: outputName)?.stringValue else {
            throw Error.predictionFailed("Missing output feature \(outputName)")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#else
public struct CoreMLTranslator {
    public func supports(source: Language, target: Language) -> Bool { false }
    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String { text }
    public init(bundle: Bundle, manifest: Any, logger: Logger) throws {}
}
#endif
