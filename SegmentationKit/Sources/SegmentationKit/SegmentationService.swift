import Foundation
import Utilities

#if canImport(CoreML)
import CoreML
#endif

#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

#if canImport(QuartzCore)
import QuartzCore
#endif

/// Lightweight representation of a segmentation request coming from the detection layer.
#if canImport(CoreVideo)
public struct SegmentationRequest {
    public let pixelBuffer: CVPixelBuffer
    public let prompt: CGRect
    public let timestamp: TimeInterval

    public init(pixelBuffer: CVPixelBuffer, prompt: CGRect, timestamp: TimeInterval = CACurrentMediaTime()) {
        self.pixelBuffer = pixelBuffer
        self.prompt = prompt
        self.timestamp = timestamp
    }
}
#endif

public enum SegmentationServiceError: Error {
    case unsupportedPlatform
    case modelNotFound(String)
    case encoderUnavailable
    case decoderUnavailable
    case failedToCreateEmbeddings
    case failedToCreateMask
}

/// Handles running SAM 3 encoder + decoder as a two-stage pipeline.
public actor SegmentationService {
    public static let shared = SegmentationService()

    private let logger: Logger

    #if canImport(CoreML)
    private var encoder: MLModel?
    private var decoder: MLModel?
    private let ciContext = CIContext()
    #if canImport(CoreVideo)
    private var cachedEmbeddings: MLMultiArray?
    private var lastFrameFingerprint: UInt64?
    private var lastFrameTimestamp: TimeInterval = 0
    private let stabilityInterval: TimeInterval = 0.35
    #endif
    #endif

    public init(logger: Logger = .shared) {
        self.logger = logger
    }

    /// Loads encoder/decoder into memory. Safe to call multiple times.
    public func prepare() async throws {
        #if canImport(CoreML)
        if encoder != nil, decoder != nil { return }

        let bundle = Bundle.module
        self.encoder = try await loadModel(named: "sam3_encoder", in: bundle)
        self.decoder = try await loadModel(named: "sam3_decoder", in: bundle)
        #else
        throw SegmentationServiceError.unsupportedPlatform
        #endif
    }

    #if canImport(CoreVideo)
    /// Main entry point triggered by the detection system.
    public func segment(_ request: SegmentationRequest) async throws -> CIImage {
        #if canImport(CoreML)
        guard let encoder, let decoder else {
            try await prepare()
            guard let encoder, let decoder else {
                throw SegmentationServiceError.modelNotFound("SAM 3 CoreML bundles missing")
            }
            _ = (encoder, decoder)
        }

        if needsNewEmbeddings(for: request) {
            cachedEmbeddings = try await runEncoder(request.pixelBuffer)
            lastFrameFingerprint = fingerprint(for: request.pixelBuffer)
            lastFrameTimestamp = request.timestamp
        }

        guard let embeddings = cachedEmbeddings else {
            throw SegmentationServiceError.failedToCreateEmbeddings
        }
        return try await runDecoder(embeddings: embeddings, prompt: request.prompt)
        #else
        throw SegmentationServiceError.unsupportedPlatform
        #endif
    }
    #endif

    // MARK: - Encoder/Decoder

    #if canImport(CoreML)
    private func loadModel(named resource: String, in bundle: Bundle) async throws -> MLModel {
        if let compiledURL = bundle.url(forResource: resource, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: compiledURL)
        }

        guard let packageURL = bundle.url(forResource: resource, withExtension: "mlpackage") else {
            throw SegmentationServiceError.modelNotFound(resource)
        }

        let compiled = try MLModel.compileModel(at: packageURL)
        return try MLModel(contentsOf: compiled)
    }

    @discardableResult
    private func runEncoder(_ pixelBuffer: CVPixelBuffer) async throws -> MLMultiArray {
        guard let encoder else { throw SegmentationServiceError.encoderUnavailable }
        let inputKey = encoder.modelDescription.imageInputKey
        let outputKey = encoder.modelDescription.multiArrayOutputKey

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputKey: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])

        let output = try encoder.prediction(from: provider)
        guard let embeddings = output.featureValue(for: outputKey)?.multiArrayValue else {
            throw SegmentationServiceError.failedToCreateEmbeddings
        }
        return embeddings
    }

    private func runDecoder(embeddings: MLMultiArray, prompt: CGRect) async throws -> CIImage {
        guard let decoder else { throw SegmentationServiceError.decoderUnavailable }

        let embeddingsKey = decoder.modelDescription.multiArrayInputKey
        let promptKey = decoder.modelDescription.promptInputKey
        let outputKey = decoder.modelDescription.imageOutputKey

        let promptArray = try MLMultiArray(shape: [1, 4], dataType: .float32)
        promptArray[0] = NSNumber(value: Float(prompt.origin.x))
        promptArray[1] = NSNumber(value: Float(prompt.origin.y))
        promptArray[2] = NSNumber(value: Float(prompt.size.width))
        promptArray[3] = NSNumber(value: Float(prompt.size.height))

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            embeddingsKey: MLFeatureValue(multiArray: embeddings),
            promptKey: MLFeatureValue(multiArray: promptArray)
        ])

        let output = try decoder.prediction(from: provider)

        if let maskPixelBuffer = output.featureValue(for: outputKey)?.imageBufferValue {
            return CIImage(cvPixelBuffer: maskPixelBuffer)
        }

        if let maskArray = output.featureValue(for: outputKey)?.multiArrayValue {
            return try ciImage(from: maskArray)
        }

        throw SegmentationServiceError.failedToCreateMask
    }

    private func ciImage(from array: MLMultiArray) throws -> CIImage {
        let width = array.shape.count > 1 ? array.shape[array.shape.count - 1].intValue : array.count
        let height = array.shape.first?.intValue ?? 1
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: array.count)
        defer { buffer.deallocate() }
        var idx = 0
        for value in array {
            buffer[idx] = value.floatValue
            idx += 1
        }
        let data = Data(bytes: buffer, count: array.count * MemoryLayout<Float>.size)
        return CIImage(bitmapData: data,
                       bytesPerRow: width * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height),
                       format: .Rf,
                       colorSpace: CGColorSpaceCreateDeviceGray())
    }
    #endif

    // MARK: - Stability
    #if canImport(CoreVideo)
    private func needsNewEmbeddings(for request: SegmentationRequest) -> Bool {
        if cachedEmbeddings == nil { return true }

        let fingerprint = fingerprint(for: request.pixelBuffer)
        guard let lastFingerprint = lastFrameFingerprint else { return true }

        if fingerprint != lastFingerprint { return true }

        return (request.timestamp - lastFrameTimestamp) > stabilityInterval
    }

    private func fingerprint(for buffer: CVPixelBuffer) -> UInt64 {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return UInt64(width ^ height ^ bytesPerRow)
        }

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleCount = min(1024, width * height / max(width, 1))

        var hash: UInt64 = 1469598103934665603
        var index = 0
        while index < sampleCount {
            hash ^= UInt64(ptr[index])
            hash &*= 1099511628211
            index += max(1, (width * height) / max(sampleCount, 1))
        }
        hash ^= UInt64(width)
        hash &*= 1099511628211
        hash ^= UInt64(height)
        hash &*= 1099511628211
        hash ^= UInt64(bytesPerRow)
        return hash
    }
    #endif
}

#if canImport(CoreML)
private extension MLModelDescription {
    var imageInputKey: String {
        if let match = inputDescriptionsByName.first(where: { $0.value.type == .image }) {
            return match.key
        }
        return inputDescriptionsByName.first?.key ?? "image"
    }

    var multiArrayInputKey: String {
        if let match = inputDescriptionsByName.first(where: { $0.value.type == .multiArray }) {
            return match.key
        }
        return inputDescriptionsByName.first?.key ?? "input"
    }

    var multiArrayOutputKey: String {
        if let match = outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) {
            return match.key
        }
        return outputDescriptionsByName.first?.key ?? "output"
    }

    var imageOutputKey: String {
        if let match = outputDescriptionsByName.first(where: { $0.value.type == .image }) {
            return match.key
        }
        return outputDescriptionsByName.first?.key ?? "mask"
    }

    var promptInputKey: String {
        if let match = inputDescriptionsByName.first(where: { $0.value.type == .multiArray && $0.key.lowercased().contains("prompt") }) {
            return match.key
        }
        return multiArrayInputKey
    }
}
#endif
