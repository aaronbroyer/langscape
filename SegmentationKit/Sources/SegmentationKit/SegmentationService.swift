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

#if canImport(CoreGraphics)
import CoreGraphics
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
    public let imageSize: CGSize

    public init(pixelBuffer: CVPixelBuffer, prompt: CGRect, imageSize: CGSize, timestamp: TimeInterval = CACurrentMediaTime()) {
        self.pixelBuffer = pixelBuffer
        self.prompt = prompt
        self.timestamp = timestamp
        self.imageSize = imageSize
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
    case invalidInput
}

/// Handles running SAM 3 encoder + decoder as a two-stage pipeline.
public actor SegmentationService {
    public static let shared = SegmentationService()

    private let logger: Logger

#if canImport(CoreML)
    private var encoder: MLModel?
    private var decoder: MLModel?
    private let ciContext = CIContext()
    private let targetImageSize = CGSize(width: 1024, height: 1024)
    private let maskResolution = 256
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
        self.encoder = try await loadModel(named: "SAM2ImageEncoder", in: bundle)
        self.decoder = try await loadModel(named: "SAM2MaskDecoder", in: bundle)
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
                throw SegmentationServiceError.modelNotFound("SAM 2.1 CoreML bundles missing")
            }
            _ = (encoder, decoder)
        }

        let preparedBuffer = try prepareInputBuffer(request.pixelBuffer)

        if needsNewEmbeddings(for: request) {
            cachedEmbeddings = try await runEncoder(preparedBuffer)
            lastFrameFingerprint = fingerprint(for: request.pixelBuffer)
            lastFrameTimestamp = request.timestamp
        }

        guard let embeddings = cachedEmbeddings else {
            throw SegmentationServiceError.failedToCreateEmbeddings
        }
        return try await runDecoder(
            embeddings: embeddings,
            prompt: request.prompt,
            originalSize: request.imageSize,
            inputImageSize: CGSize(width: CVPixelBufferGetWidth(preparedBuffer), height: CVPixelBufferGetHeight(preparedBuffer))
        )
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

    private func runDecoder(embeddings: MLMultiArray, prompt: CGRect, originalSize: CGSize, inputImageSize: CGSize) async throws -> CIImage {
        guard let decoder else { throw SegmentationServiceError.decoderUnavailable }

        let embeddingsKey = "image_embeddings"
        let coordsKey = "point_coords"
        let labelsKey = "point_labels"
        let maskInputKey = "mask_input"
        let hasMaskInputKey = "has_mask_input"
        let origSizeKey = "orig_im_size"
        let outputKey = decoder.modelDescription.multiArrayOutputKey

        let coords = try convertBoxToPrompts(prompt, originalSize: originalSize, inputImageSize: inputImageSize)
        let labels = try boxPromptLabels()
        let maskInput = try emptyMaskInput()
        let origImSize = try originalImageSizeArray(originalSize)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            embeddingsKey: MLFeatureValue(multiArray: embeddings),
            coordsKey: MLFeatureValue(multiArray: coords),
            labelsKey: MLFeatureValue(multiArray: labels),
            maskInputKey: MLFeatureValue(multiArray: maskInput),
            hasMaskInputKey: MLFeatureValue(double: 0),
            origSizeKey: MLFeatureValue(multiArray: origImSize)
        ])

        let output = try decoder.prediction(from: provider)

        if let maskArray = output.featureValue(for: outputKey)?.multiArrayValue {
            return try convertLogitsToMask(maskArray)
        }

        throw SegmentationServiceError.failedToCreateMask
    }

    private func convertLogitsToMask(_ logits: MLMultiArray) throws -> CIImage {
        guard logits.shape.count >= 4 else { throw SegmentationServiceError.failedToCreateMask }
        let height = logits.shape[logits.shape.count - 2].intValue
        let width = logits.shape[logits.shape.count - 1].intValue
        let total = width * height
        var values = [Float](repeating: 0, count: total)
        let threshold: Float = 0.5
        for idx in 0..<total {
            let value = logits[idx].floatValue
            let sigmoid = 1.0 / (1.0 + exp(-value))
            values[idx] = sigmoid >= threshold ? 1.0 : 0.0
        }
        let data = Data(bytes: values, count: values.count * MemoryLayout<Float>.size)
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .Rf,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
    }

    private func prepareInputBuffer(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let desiredWidth = Int(targetImageSize.width)
        let desiredHeight = Int(targetImageSize.height)
        if width == desiredWidth, height == desiredHeight {
            return buffer
        }

        var resized: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            desiredWidth,
            desiredHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &resized
        )
        guard status == kCVReturnSuccess, let output = resized else {
            throw SegmentationServiceError.invalidInput
        }

        let inputImage = CIImage(cvPixelBuffer: buffer)
        let scaleX = targetImageSize.width / CGFloat(width)
        let scaleY = targetImageSize.height / CGFloat(height)
        let scaled = inputImage
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(origin: .zero, size: targetImageSize))
        ciContext.render(scaled, to: output)
        return output
    }

    private func convertBoxToPrompts(_ prompt: CGRect, originalSize: CGSize, inputImageSize: CGSize) throws -> MLMultiArray {
        let coords = try MLMultiArray(shape: [1, 2, 2], dataType: .float32)
        let sx = inputImageSize.width / max(originalSize.width, 1)
        let sy = inputImageSize.height / max(originalSize.height, 1)
        let topLeft = CGPoint(x: prompt.minX * sx, y: prompt.minY * sy)
        let bottomRight = CGPoint(x: prompt.maxX * sx, y: prompt.maxY * sy)
        coords[0] = NSNumber(value: Float(topLeft.x))
        coords[1] = NSNumber(value: Float(topLeft.y))
        coords[2] = NSNumber(value: Float(bottomRight.x))
        coords[3] = NSNumber(value: Float(bottomRight.y))
        return coords
    }

    private func boxPromptLabels() throws -> MLMultiArray {
        let labels = try MLMultiArray(shape: [1, 2], dataType: .float32)
        labels[0] = 2 // SAM box start token
        labels[1] = 3 // SAM box end token
        return labels
    }

    private func emptyMaskInput() throws -> MLMultiArray {
        return try MLMultiArray(shape: [1, 1, NSNumber(value: maskResolution), NSNumber(value: maskResolution)], dataType: .float32)
    }

    private func originalImageSizeArray(_ size: CGSize) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [2], dataType: .float32)
        array[0] = NSNumber(value: Float(size.height))
        array[1] = NSNumber(value: Float(size.width))
        return array
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
