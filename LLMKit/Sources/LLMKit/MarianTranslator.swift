import Foundation
import Utilities
#if canImport(CoreML)
import CoreML
#endif

public struct MarianTranslator: TranslationProviding, @unchecked Sendable {
    public struct Config: Sendable {
        public let maxInputTokens: Int
        public let maxOutputTokens: Int
        public let decoderStartTokenId: Int
        public let eosTokenId: Int
        public let padTokenId: Int

        public init(
            maxInputTokens: Int = 32,
            maxOutputTokens: Int = 32,
            decoderStartTokenId: Int = 59513,
            eosTokenId: Int = 0,
            padTokenId: Int = 59513
        ) {
            self.maxInputTokens = maxInputTokens
            self.maxOutputTokens = maxOutputTokens
            self.decoderStartTokenId = decoderStartTokenId
            self.eosTokenId = eosTokenId
            self.padTokenId = padTokenId
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case modelNotFound(String)
        case tokenizerUnavailable(String)
        case vocabUnavailable(String)
        case predictionFailed(String)
        case invalidOutput

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let message),
                 .tokenizerUnavailable(let message),
                 .vocabUnavailable(let message),
                 .predictionFailed(let message):
                return message
            case .invalidOutput:
                return "Decoder produced no tokens."
            }
        }
    }

    private let encoderModel: MLModel
    private let decoderModel: MLModel
    private let sourceTokenizer: SentencePieceTokenizer
    private let targetTokenizer: SentencePieceTokenizer
    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]
    private let unkTokenId: Int
    private let config: Config
    private let supportedPair: (source: Language, target: Language)
    private let logger: Logger

    public init(
        bundle: Bundle,
        encoderModel: String,
        decoderModel: String,
        sourceTokenizer: String,
        targetTokenizer: String,
        vocabFile: String,
        source: Language,
        target: Language,
        config: Config = Config(),
        logger: Logger = .shared
    ) throws {
        #if canImport(CoreML)
        self.encoderModel = try MarianTranslator.loadModel(from: bundle, named: encoderModel)
        self.decoderModel = try MarianTranslator.loadModel(from: bundle, named: decoderModel)
        #else
        throw Error.modelNotFound("CoreML is unavailable on this platform.")
        #endif

        guard let sourceURL = Self.resolveResourceURL(sourceTokenizer, bundle: bundle) else {
            throw Error.tokenizerUnavailable("Missing source tokenizer resource: \(sourceTokenizer)")
        }
        guard let targetURL = Self.resolveResourceURL(targetTokenizer, bundle: bundle) else {
            throw Error.tokenizerUnavailable("Missing target tokenizer resource: \(targetTokenizer)")
        }

        do {
            self.sourceTokenizer = try SentencePieceTokenizer(modelURL: sourceURL)
            self.targetTokenizer = try SentencePieceTokenizer(modelURL: targetURL)
        } catch {
            throw Error.tokenizerUnavailable("Failed to load tokenizers: \(error.localizedDescription)")
        }

        guard let vocabURL = Self.resolveResourceURL(vocabFile, bundle: bundle) else {
            throw Error.vocabUnavailable("Missing vocab resource: \(vocabFile)")
        }

        do {
            let data = try Data(contentsOf: vocabURL)
            let vocab = try JSONDecoder().decode([String: Int].self, from: data)
            self.vocab = vocab
            var reverse: [Int: String] = [:]
            reverse.reserveCapacity(vocab.count)
            for (token, id) in vocab where reverse[id] == nil {
                reverse[id] = token
            }
            self.reverseVocab = reverse
            self.unkTokenId = vocab["<unk>"] ?? 1
        } catch {
            throw Error.vocabUnavailable("Failed to load vocab: \(error.localizedDescription)")
        }

        self.config = config
        self.supportedPair = (source: source, target: target)
        self.logger = logger
    }

    public func supports(source: Language, target: Language) -> Bool {
        supportedPair.source == source && supportedPair.target == target
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        guard supports(source: source, target: target) else {
            throw Error.predictionFailed("Unsupported translation pair.")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let encoded: [Int]
        do {
            encoded = try sourceTokenizer.encode(trimmed)
        } catch {
            await logger.log("SentencePiece encode failed: \(error.localizedDescription)", level: .error, category: "LLMKit.MarianTranslator")
            throw Error.tokenizerUnavailable("SentencePiece encode failed: \(error.localizedDescription)")
        }

        let mappedTokens: [Int]
        do {
            mappedTokens = try encoded.map { tokenId in
                let piece = try sourceTokenizer.idToToken(tokenId)
                return vocab[piece] ?? unkTokenId
            }
        } catch {
            await logger.log("SentencePiece token mapping failed: \(error.localizedDescription)", level: .error, category: "LLMKit.MarianTranslator")
            throw Error.tokenizerUnavailable("SentencePiece token mapping failed: \(error.localizedDescription)")
        }

        var inputTokens = mappedTokens
        let maxInput = max(1, config.maxInputTokens)
        if inputTokens.count >= maxInput {
            inputTokens = Array(inputTokens.prefix(maxInput - 1))
        }
        if inputTokens.last != config.eosTokenId {
            inputTokens.append(config.eosTokenId)
        }

        let inputIds = try MarianTranslator.makeIntArray(length: maxInput, fill: config.padTokenId)
        let attentionMask = try MarianTranslator.makeIntArray(length: maxInput, fill: 0)

        for (idx, token) in inputTokens.enumerated() {
            MarianTranslator.setInt(inputIds, index: idx, value: token)
            MarianTranslator.setInt(attentionMask, index: idx, value: 1)
        }

        let encoderProvider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIds,
            "attention_mask": attentionMask
        ])
        let encoderOutput: MLFeatureProvider
        do {
            encoderOutput = try await encoderModel.prediction(from: encoderProvider)
        } catch {
            throw Error.predictionFailed(error.localizedDescription)
        }

        guard let encoderHiddenStates = encoderOutput.featureValue(for: "encoder_hidden_states")?.multiArrayValue else {
            throw Error.predictionFailed("Missing encoder_hidden_states output.")
        }

        let decoderInputIds = try MarianTranslator.makeIntArray(length: config.maxOutputTokens, fill: config.padTokenId)
        MarianTranslator.setInt(decoderInputIds, index: 0, value: config.decoderStartTokenId)

        var generated: [Int] = []
        let maxSteps = max(1, config.maxOutputTokens - 1)

        for step in 0..<maxSteps {
            let decoderProvider = try MLDictionaryFeatureProvider(dictionary: [
                "decoder_input_ids": decoderInputIds,
                "encoder_hidden_states": encoderHiddenStates,
                "encoder_attention_mask": attentionMask
            ])

            let decoderOutput: MLFeatureProvider
            do {
                decoderOutput = try await decoderModel.prediction(from: decoderProvider)
            } catch {
                throw Error.predictionFailed(error.localizedDescription)
            }

            guard let logits = decoderOutput.featureValue(for: "logits")?.multiArrayValue else {
                throw Error.predictionFailed("Missing logits output.")
            }

            let nextToken = try MarianTranslator.argmaxToken(from: logits, at: step)
            if nextToken == config.eosTokenId {
                break
            }

            generated.append(nextToken)
            if step + 1 < config.maxOutputTokens {
                MarianTranslator.setInt(decoderInputIds, index: step + 1, value: nextToken)
            }
        }

        guard !generated.isEmpty else {
            throw Error.invalidOutput
        }

        var pieces: [String] = []
        pieces.reserveCapacity(generated.count)
        for tokenId in generated {
            if tokenId == config.eosTokenId {
                break
            }
            if tokenId == config.padTokenId {
                continue
            }
            if let piece = reverseVocab[tokenId] {
                if piece == "<pad>" {
                    continue
                }
                pieces.append(piece)
            } else {
                pieces.append("<unk>")
            }
        }

        guard !pieces.isEmpty else {
            throw Error.invalidOutput
        }

        let spmIds = pieces.map { targetTokenizer.tokenToId($0) }
        do {
            let decoded = try targetTokenizer.decode(spmIds)
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await logger.log("SentencePiece decode failed: \(error.localizedDescription)", level: .error, category: "LLMKit.MarianTranslator")
            throw Error.tokenizerUnavailable("SentencePiece decode failed: \(error.localizedDescription)")
        }
    }

    private static func loadModel(from bundle: Bundle, named resource: String) throws -> MLModel {
        guard let modelURL = resolveModelURL(resource, bundle: bundle) else {
            throw Error.modelNotFound("Missing CoreML model resource: \(resource)")
        }

        guard modelURL.pathExtension != "mlmodel" else {
            throw Error.modelNotFound("Model must be compiled (.mlpackage/.mlmodelc): \(resource)")
        }

        return try MLModel(contentsOf: modelURL)
    }

    private static func resolveModelURL(_ resource: String, bundle: Bundle) -> URL? {
        if let direct = bundle.url(forResource: resource, withExtension: nil) {
            return direct
        }

        let resourceName = (resource as NSString).deletingPathExtension
        let ext = (resource as NSString).pathExtension

        if !resourceName.isEmpty, !ext.isEmpty {
            if let url = bundle.url(forResource: resourceName, withExtension: ext) {
                return url
            }
            if ext == "mlpackage", let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc") {
                return url
            }
            if ext == "mlmodelc", let url = bundle.url(forResource: resourceName, withExtension: "mlpackage") {
                return url
            }
        } else if ext.isEmpty {
            if let url = bundle.url(forResource: resource, withExtension: "mlmodelc") {
                return url
            }
            if let url = bundle.url(forResource: resource, withExtension: "mlpackage") {
                return url
            }
        }

        return nil
    }

    private static func resolveResourceURL(_ resource: String, bundle: Bundle) -> URL? {
        if let direct = bundle.url(forResource: resource, withExtension: nil) {
            return direct
        }
        let resourceName = (resource as NSString).deletingPathExtension
        let ext = (resource as NSString).pathExtension
        if !resourceName.isEmpty, !ext.isEmpty {
            return bundle.url(forResource: resourceName, withExtension: ext)
        }
        return nil
    }

    private static func makeIntArray(length: Int, fill: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
        for idx in 0..<array.count {
            ptr[idx] = Int32(fill)
        }
        return array
    }

    private static func setInt(_ array: MLMultiArray, index: Int, value: Int) {
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
        ptr[index] = Int32(value)
    }

    private static func argmaxToken(from logits: MLMultiArray, at position: Int) throws -> Int {
        let shape = logits.shape.map { $0.intValue }
        guard shape.count == 3 else {
            throw Error.predictionFailed("Unexpected logits shape.")
        }
        let vocabSize = shape[2]
        let strides = logits.strides.map { $0.intValue }
        let base = position * strides[1]

        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.bindMemory(to: Float32.self, capacity: logits.count)
            var maxValue = -Float32.greatestFiniteMagnitude
            var maxIndex = 0
            for i in 0..<vocabSize {
                let value = ptr[base + i * strides[2]]
                if value > maxValue {
                    maxValue = value
                    maxIndex = i
                }
            }
            return maxIndex
        case .float16:
            let ptr = logits.dataPointer.bindMemory(to: UInt16.self, capacity: logits.count)
            var maxValue = -Float.greatestFiniteMagnitude
            var maxIndex = 0
            for i in 0..<vocabSize {
                let raw = ptr[base + i * strides[2]]
                let value = Float(Float16(bitPattern: raw))
                if value > maxValue {
                    maxValue = value
                    maxIndex = i
                }
            }
            return maxIndex
        case .double:
            let ptr = logits.dataPointer.bindMemory(to: Double.self, capacity: logits.count)
            var maxValue = -Double.greatestFiniteMagnitude
            var maxIndex = 0
            for i in 0..<vocabSize {
                let value = ptr[base + i * strides[2]]
                if value > maxValue {
                    maxValue = value
                    maxIndex = i
                }
            }
            return maxIndex
        default:
            throw Error.predictionFailed("Unsupported logits data type.")
        }
    }
}
