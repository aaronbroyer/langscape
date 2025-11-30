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

#if canImport(CoreVideo)
extension SegmentationRequest: @unchecked Sendable {}
#endif

public enum SegmentationServiceError: Error {
    case unsupportedPlatform
    case modelNotFound(String)
    case encoderUnavailable
    case decoderUnavailable
    case failedToCreateEmbeddings
    case failedToCreatePromptEmbeddings
    case failedToCreateMask
    case invalidInput
}

/// Handles running SAM 3 encoder + decoder as a two-stage pipeline.
public actor SegmentationService {
    public static let shared = SegmentationService()

    private let logger: Logger

#if canImport(CoreML)
    private struct ImageFeatures {
        let imageEmbedding: MLMultiArray
        let featsS0: MLMultiArray
        let featsS1: MLMultiArray
    }

    private struct PromptEmbeddings {
        let sparse: MLMultiArray
        let dense: MLMultiArray
    }

    private var encoder: MLModel?
    private var promptEncoder: MLModel?
    private var decoder: MLModel?
    private let ciContext = CIContext()
    private let targetImageSize = CGSize(width: 1024, height: 1024)
#if canImport(CoreVideo)
    private var cachedImageFeatures: ImageFeatures?
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
        if encoder != nil, decoder != nil, promptEncoder != nil { return }

        let bundle = Bundle.module
        self.encoder = try loadModel(named: "SAM2_1SmallImageEncoderFLOAT16", in: bundle)
        self.promptEncoder = try loadModel(named: "SAM2_1SmallPromptEncoderFLOAT16", in: bundle)
        self.decoder = try loadModel(named: "SAM2_1SmallMaskDecoderFLOAT16", in: bundle)
        #else
        throw SegmentationServiceError.unsupportedPlatform
        #endif
    }

    #if canImport(CoreVideo)
    /// Main entry point triggered by the detection system.
    public func segment(_ request: SegmentationRequest) async throws -> CIImage {
        #if canImport(CoreML)
        if encoder == nil || decoder == nil || promptEncoder == nil {
            try await prepare()
        }
        guard let encoder else { throw SegmentationServiceError.encoderUnavailable }
        guard let promptEncoder else { throw SegmentationServiceError.modelNotFound("SAM prompt encoder missing") }
        guard let decoder else { throw SegmentationServiceError.decoderUnavailable }

        let preparedBuffer = try prepareInputBuffer(request.pixelBuffer)
        let inputImageSize = CGSize(width: CVPixelBufferGetWidth(preparedBuffer), height: CVPixelBufferGetHeight(preparedBuffer))

        if needsNewEmbeddings(for: request) {
            cachedImageFeatures = try runEncoder(preparedBuffer, encoder: encoder)
            lastFrameFingerprint = fingerprint(for: request.pixelBuffer)
            lastFrameTimestamp = request.timestamp
        }

        guard let imageFeatures = cachedImageFeatures else {
            throw SegmentationServiceError.failedToCreateEmbeddings
        }

        let promptPoints = try convertBoxToPrompts(request.prompt, originalSize: request.imageSize, inputImageSize: inputImageSize)
        let promptLabels = try boxPromptLabels()
        let promptEmbeddings = try runPromptEncoder(points: promptPoints, labels: promptLabels, promptEncoder: promptEncoder)

        return try runDecoder(
            imageFeatures: imageFeatures,
            promptEmbeddings: promptEmbeddings,
            decoder: decoder,
            originalSize: request.imageSize,
            prompt: request.prompt
        )
        #else
        throw SegmentationServiceError.unsupportedPlatform
        #endif
    }
    #endif

    // MARK: - Encoder/Decoder

    #if canImport(CoreML)
    private func loadModel(named resource: String, in bundle: Bundle) throws -> MLModel {
        if let compiledURL = bundle.url(forResource: resource, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: compiledURL)
        }

        guard let packageURL = bundle.url(forResource: resource, withExtension: "mlpackage") else {
            throw SegmentationServiceError.modelNotFound(resource)
        }

        let compiled = try MLModel.compileModel(at: packageURL)
        return try MLModel(contentsOf: compiled)
    }

    private func runEncoder(_ pixelBuffer: CVPixelBuffer, encoder: MLModel) throws -> ImageFeatures {
        let inputKey = encoder.modelDescription.imageInputKey

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputKey: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])

        let output = try encoder.prediction(from: provider)
        guard
            let imageEmbedding = output.featureValue(for: "image_embedding")?.multiArrayValue,
            let featsS0 = output.featureValue(for: "feats_s0")?.multiArrayValue,
            let featsS1 = output.featureValue(for: "feats_s1")?.multiArrayValue
        else {
            throw SegmentationServiceError.failedToCreateEmbeddings
        }
        return ImageFeatures(imageEmbedding: imageEmbedding, featsS0: featsS0, featsS1: featsS1)
    }

    private func runPromptEncoder(points: MLMultiArray, labels: MLMultiArray, promptEncoder: MLModel) throws -> PromptEmbeddings {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: points),
            "labels": MLFeatureValue(multiArray: labels)
        ])
        let output = try promptEncoder.prediction(from: provider)
        guard
            let sparse = output.featureValue(for: "sparse_embeddings")?.multiArrayValue,
            let dense = output.featureValue(for: "dense_embeddings")?.multiArrayValue
        else {
            throw SegmentationServiceError.failedToCreatePromptEmbeddings
        }
        return PromptEmbeddings(sparse: sparse, dense: dense)
    }

    private func runDecoder(
        imageFeatures: ImageFeatures,
        promptEmbeddings: PromptEmbeddings,
        decoder: MLModel,
        originalSize: CGSize,
        prompt: CGRect
    ) throws -> CIImage {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": MLFeatureValue(multiArray: imageFeatures.imageEmbedding),
            "sparse_embedding": MLFeatureValue(multiArray: promptEmbeddings.sparse),
            "dense_embedding": MLFeatureValue(multiArray: promptEmbeddings.dense),
            "feats_s0": MLFeatureValue(multiArray: imageFeatures.featsS0),
            "feats_s1": MLFeatureValue(multiArray: imageFeatures.featsS1)
        ])

        let output = try decoder.prediction(from: provider)

        guard
            let maskArray = output.featureValue(for: "low_res_masks")?.multiArrayValue,
            let scoresArray = output.featureValue(for: "scores")?.multiArrayValue
        else {
            throw SegmentationServiceError.failedToCreateMask
        }

        let bestMaskIndex = bestMaskIndex(from: scoresArray)
        return try convertLogitsToMask(maskArray, maskIndex: bestMaskIndex, originalSize: originalSize, prompt: prompt)
    }

    private func bestMaskIndex(from scores: MLMultiArray) -> Int {
        var bestIndex = 0
        var bestScore = -Float.greatestFiniteMagnitude
        for idx in 0..<scores.count {
            let score = scores[idx].floatValue
            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }
        return bestIndex
    }

    private func convertLogitsToMask(_ logits: MLMultiArray, maskIndex: Int, originalSize: CGSize, prompt: CGRect) throws -> CIImage {
        guard logits.shape.count == 4 else { throw SegmentationServiceError.failedToCreateMask }
        let batch = logits.shape[0].intValue
        let channels = logits.shape[1].intValue
        guard batch > 0, maskIndex < channels else { throw SegmentationServiceError.failedToCreateMask }
        let height = logits.shape[2].intValue
        let width = logits.shape[3].intValue
        let total = width * height
        var values = [Float](repeating: 0, count: total)
        let fullSize = CGSize(width: max(originalSize.width, 1), height: max(originalSize.height, 1))
        var boundedPrompt = prompt.standardized.intersection(CGRect(origin: .zero, size: fullSize))
        if boundedPrompt.isNull || boundedPrompt.width <= 1 || boundedPrompt.height <= 1 {
            boundedPrompt = CGRect(origin: .zero, size: fullSize)
        }
        let expansionX = boundedPrompt.width * 0.2
        let expansionY = boundedPrompt.height * 0.2
        let expandedPrompt = boundedPrompt
            .insetBy(dx: -expansionX, dy: -expansionY)
            .intersection(CGRect(origin: .zero, size: fullSize))
        let roiMinX = Int(max(0, floor(expandedPrompt.minX / fullSize.width * CGFloat(width))))
        let roiMaxX = Int(min(CGFloat(width - 1), ceil(expandedPrompt.maxX / fullSize.width * CGFloat(width))))
        let roiMinY = Int(max(0, floor(expandedPrompt.minY / fullSize.height * CGFloat(height))))
        let roiMaxY = Int(min(CGFloat(height - 1), ceil(expandedPrompt.maxY / fullSize.height * CGFloat(height))))
        let maskThreshold: Double = 0.6
        for y in 0..<height {
            for x in 0..<width {
                let withinROI = x >= roiMinX && x <= roiMaxX && y >= roiMinY && y <= roiMaxY
                let idx = [
                    NSNumber(value: 0),
                    NSNumber(value: maskIndex),
                    NSNumber(value: y),
                    NSNumber(value: x)
                ]
                let value = logits[idx].doubleValue
                let probability = 1.0 / (1.0 + exp(-value))
                let shouldKeep = withinROI && probability >= maskThreshold
                values[y * width + x] = shouldKeep ? Float(probability) : 0
            }
        }
        let data = Data(bytes: values, count: values.count * MemoryLayout<Float>.size)
#if canImport(CoreImage)
        if let refined = upscaleAndThresholdMask(
            data: data,
            sourceSize: CGSize(width: width, height: height),
            targetRect: expandedPrompt,
            fullSize: fullSize
        ) {
            let flip = CGAffineTransform(translationX: 0, y: refined.extent.height).scaledBy(x: 1, y: -1)
            return refined.transformed(by: flip)
        }
#endif
        var maskImage = CIImage(
            bitmapData: data,
            bytesPerRow: width * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .Rf,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        let scaleX = fullSize.width / CGFloat(width)
        let scaleY = fullSize.height / CGFloat(height)
        if scaleX > 0, scaleY > 0 {
            maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        maskImage = maskImage
            .transformed(by: CGAffineTransform(translationX: expandedPrompt.minX, y: expandedPrompt.minY))
            .cropped(to: CGRect(origin: .zero, size: fullSize))
        let flip = CGAffineTransform(translationX: 0, y: maskImage.extent.height).scaledBy(x: 1, y: -1)
        return maskImage.transformed(by: flip)
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
        let coords = try MLMultiArray(shape: [1, 2, 2], dataType: .float16)
        let sx = inputImageSize.width / max(originalSize.width, 1)
        let sy = inputImageSize.height / max(originalSize.height, 1)
        let topLeft = CGPoint(x: prompt.minX * sx, y: prompt.minY * sy)
        let bottomRight = CGPoint(x: prompt.maxX * sx, y: prompt.maxY * sy)
        setCoords(coords, batch: 0, point: 0, x: Float(topLeft.x), y: Float(topLeft.y))
        setCoords(coords, batch: 0, point: 1, x: Float(bottomRight.x), y: Float(bottomRight.y))
        return coords
    }

    private func boxPromptLabels() throws -> MLMultiArray {
        let labels = try MLMultiArray(shape: [1, 2], dataType: .float16)
        setLabel(labels, batch: 0, index: 0, value: 2)
        setLabel(labels, batch: 0, index: 1, value: 3)
        return labels
    }

    private func setCoords(_ array: MLMultiArray, batch: Int, point: Int, x: Float, y: Float) {
        array[[NSNumber(value: batch), NSNumber(value: point), NSNumber(value: 0)]] = NSNumber(value: x)
        array[[NSNumber(value: batch), NSNumber(value: point), NSNumber(value: 1)]] = NSNumber(value: y)
    }

    private func setLabel(_ array: MLMultiArray, batch: Int, index: Int, value: Float) {
        array[[NSNumber(value: batch), NSNumber(value: index)]] = NSNumber(value: value)
    }
    #endif

    // MARK: - Stability
    #if canImport(CoreVideo)
    private func needsNewEmbeddings(for request: SegmentationRequest) -> Bool {
        if cachedImageFeatures == nil { return true }

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

#if canImport(CoreImage)
private func upscaleAndThresholdMask(
    data: Data,
    sourceSize: CGSize,
    targetRect: CGRect,
    fullSize: CGSize
) -> CIImage? {
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
    let base = CIImage(
        bitmapData: data,
        bytesPerRow: Int(sourceSize.width) * MemoryLayout<Float>.size,
        size: sourceSize,
        format: .Rf,
        colorSpace: CGColorSpaceCreateDeviceGray()
    )
    let scaleX = max(targetRect.width, 1) / max(sourceSize.width, 1)
    let scaleY = max(targetRect.height, 1) / max(sourceSize.height, 1)
    let lanczosScale = max(scaleY, 0.0001)
    let aspect = max(lanczosScale / max(scaleX, 0.0001), 0.0001)
    var result = base.applyingFilter(
        "CILanczosScaleTransform",
        parameters: [
            kCIInputScaleKey: lanczosScale,
            kCIInputAspectRatioKey: aspect
        ]
    )
    if let threshold = CIFilter(name: "CIColorMatrix") {
        threshold.setValue(result, forKey: kCIInputImageKey)
        threshold.setValue(CIVector(x: 0, y: 0, z: 0, w: 20), forKey: "inputAVector")
        threshold.setValue(CIVector(x: 0, y: 0, z: 0, w: -10), forKey: "inputBiasVector")
        if let output = threshold.outputImage {
            result = output
        }
    }
    result = result.cropped(to: CGRect(origin: .zero, size: targetRect.size))
    result = result.transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))
    return result.cropped(to: CGRect(origin: .zero, size: fullSize))
}
#endif
