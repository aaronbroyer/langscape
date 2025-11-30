import Foundation
import Utilities

#if canImport(CoreML)
import CoreML
#endif

#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
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

@available(macOS 15.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public actor SegmentationService {
    public static let shared = SegmentationService()
    private let logger: Logger

#if canImport(CoreML)
    private let encoderConfiguration: MLModelConfiguration
    private let promptConfiguration: MLModelConfiguration
    private let decoderConfiguration: MLModelConfiguration
    
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
    private var prepareTask: Task<Void, Error>?
    
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let targetImageSize = CGSize(width: 1024, height: 1024) // SAM 2 Standard
    
#if canImport(CoreVideo)
    private var cachedImageFeatures: ImageFeatures?
    private var lastFrameFingerprint: UInt64?
    private var lastFrameTimestamp: TimeInterval = 0
    private let stabilityInterval: TimeInterval = 0.2 // Slightly faster updates
#endif
#endif

    public init(logger: Logger = .shared) {
        self.logger = logger
#if canImport(CoreML)
        // 1. Image Encoder: Heavy, uses Neural Engine
        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = .all
        self.encoderConfiguration = encoderConfiguration

        // 2. Prompt Encoder: Tiny but buggy on ANE, FORCE CPU
        let promptConfiguration = MLModelConfiguration()
        promptConfiguration.computeUnits = .cpuOnly 
        self.promptConfiguration = promptConfiguration

        // 3. Mask Decoder: Medium, uses Neural Engine
        let decoderConfiguration = MLModelConfiguration()
        decoderConfiguration.computeUnits = .all
        self.decoderConfiguration = decoderConfiguration
#endif
    }

    public func prepare() async throws {
#if canImport(CoreML)
        if let task = prepareTask { try await task.value; return }
        if encoder != nil, decoder != nil, promptEncoder != nil { return }

        let task = Task { try await self.loadSegmentationModels() }
        prepareTask = task
        do { try await task.value } catch { prepareTask = nil; throw error }
        prepareTask = nil
#else
        throw SegmentationServiceError.unsupportedPlatform
#endif
    }

#if canImport(CoreML)
    private func loadSegmentationModels() async throws {
        let bundle = Bundle.module
        // Load Official Apple Models
        self.encoder = try loadModel(named: "SAM2_1SmallImageEncoderFLOAT16", in: bundle, configuration: encoderConfiguration)
        self.promptEncoder = try loadModel(named: "SAM2_1SmallPromptEncoderFLOAT16", in: bundle, configuration: promptConfiguration)
        self.decoder = try loadModel(named: "SAM2_1SmallMaskDecoderFLOAT16", in: bundle, configuration: decoderConfiguration)
        await logger.log("✅ SAM 2.1 Models Loaded (PromptEncoder CPU-Forced)", level: .info, category: "SegmentationKit")
    }
#endif

#if canImport(CoreVideo)
    public func segment(_ request: SegmentationRequest) async throws -> CIImage {
#if canImport(CoreML)
        guard let encoder, let promptEncoder, let decoder else {
            try await prepare()
            return try await segment(request) // Retry once
        }

        // 1. Resize Input to 1024x1024 (Standard SAM input)
        let preparedBuffer = try prepareInputBuffer(request.pixelBuffer)

        // 2. Run Image Encoder (Cached)
        if needsNewEmbeddings(for: request) {
            cachedImageFeatures = try runEncoder(preparedBuffer, encoder: encoder)
            lastFrameFingerprint = fingerprint(for: request.pixelBuffer)
            lastFrameTimestamp = request.timestamp
        }
        guard let imageFeatures = cachedImageFeatures else { throw SegmentationServiceError.failedToCreateEmbeddings }

        // 3. Run Prompt Encoder (CPU)
        // convertBoxToPrompts FIX: No Y-Flipping!
        let (points, labels) = try convertBoxToPrompts(request.prompt, originalSize: request.imageSize, inputImageSize: targetImageSize)
        let promptEmbeddings = try runPromptEncoder(points: points, labels: labels, promptEncoder: promptEncoder)

        // 4. Run Mask Decoder
        let result = try runDecoder(
            imageFeatures: imageFeatures,
            promptEmbeddings: promptEmbeddings,
            decoder: decoder,
            originalSize: request.imageSize,
            prompt: request.prompt
        )
        
        return result
#else
        throw SegmentationServiceError.unsupportedPlatform
#endif
    }
#endif

    // MARK: - Core Logic

#if canImport(CoreML)
    private func loadModel(named resource: String, in bundle: Bundle, configuration: MLModelConfiguration) throws -> MLModel {
        if let url = bundle.url(forResource: resource, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        if let url = bundle.url(forResource: resource, withExtension: "mlpackage") {
            let compiled = try MLModel.compileModel(at: url)
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        throw SegmentationServiceError.modelNotFound(resource)
    }

    private func runEncoder(_ pixelBuffer: CVPixelBuffer, encoder: MLModel) throws -> ImageFeatures {
        let inputKey = "image" // Apple model uses 'image'
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputKey: MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try encoder.prediction(from: provider)
        
        // Apple Model Output Keys
        guard let embedding = output.featureValue(for: "image_embedding")?.multiArrayValue,
              let s0 = output.featureValue(for: "feats_s0")?.multiArrayValue,
              let s1 = output.featureValue(for: "feats_s1")?.multiArrayValue else {
            throw SegmentationServiceError.failedToCreateEmbeddings
        }
        return ImageFeatures(imageEmbedding: embedding, featsS0: s0, featsS1: s1)
    }

    private func runPromptEncoder(points: MLMultiArray, labels: MLMultiArray, promptEncoder: MLModel) throws -> PromptEmbeddings {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: points),
            "labels": MLFeatureValue(multiArray: labels)
        ])
        let output = try promptEncoder.prediction(from: provider)
        guard let sparse = output.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = output.featureValue(for: "dense_embeddings")?.multiArrayValue else {
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
        guard let lowResMasks = output.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            throw SegmentationServiceError.failedToCreateMask
        }
        
        // Pick best mask (highest IoU score)
        var bestIdx = 0
        var bestScore: Float = -1000.0
        let count = scores.count
        for i in 0..<count {
            let s = scores[i].floatValue
            if s > bestScore { bestScore = s; bestIdx = i }
        }
        
        // If SAM is unsure (low score), you might want to return empty, but for now we return best.
        return try convertLogitsToMask(lowResMasks, maskIndex: bestIdx, originalSize: originalSize, prompt: prompt)
    }

    private func convertLogitsToMask(_ logits: MLMultiArray, maskIndex: Int, originalSize: CGSize, prompt: CGRect) throws -> CIImage {
        guard logits.shape.count == 4 else { throw SegmentationServiceError.failedToCreateMask }
        let channels = logits.shape[1].intValue
        let height = logits.shape[2].intValue
        let width = logits.shape[3].intValue
        let total = width * height
        guard channels > 0, maskIndex < channels, total > 0 else {
            throw SegmentationServiceError.failedToCreateMask
        }

        var pixels = [UInt8](repeating: 0, count: total * 4)
        let floatPointer = UnsafePointer<Float>(OpaquePointer(logits.dataPointer))
        let channelOffset = maskIndex * total

        for index in 0..<total {
            let value = floatPointer[channelOffset + index]
            if value > 0 {
                let pixelIndex = index * 4
                pixels[pixelIndex] = 255
                pixels[pixelIndex + 1] = 255
                pixels[pixelIndex + 2] = 255
                pixels[pixelIndex + 3] = 255
            }
        }

        let data = Data(pixels)
        let base = CIImage(
            bitmapData: data,
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return stylizeOutline(base, prompt: prompt, originalSize: originalSize)
    }

    private func stylizeOutline(_ mask: CIImage, prompt: CGRect, originalSize: CGSize) -> CIImage {
        let scaleX = max(originalSize.width, 1) / max(mask.extent.width, 1)
        let scaleY = max(originalSize.height, 1) / max(mask.extent.height, 1)
        let upscaled = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let thresholdFilter = CIFilter.colorThreshold()
        thresholdFilter.inputImage = upscaled
        thresholdFilter.threshold = 0.5
        guard let thresholded = thresholdFilter.outputImage else {
            return upscaled
        }

        let gradient = CIFilter.morphologyGradient()
        gradient.inputImage = thresholded
        gradient.radius = 3
        guard let edges = gradient.outputImage else {
            return thresholded
        }

        let cyan = CIImage(color: CIColor(red: 0, green: 1, blue: 1, alpha: 1)).cropped(to: edges.extent)
        let clear = CIImage(color: .clear).cropped(to: edges.extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = cyan
        blend.backgroundImage = clear
        blend.maskImage = edges
        var outlined = blend.outputImage ?? edges

        let bloom = CIFilter.bloom()
        bloom.inputImage = outlined
        bloom.intensity = 1.0
        bloom.radius = 10.0
        if let bloomed = bloom.outputImage {
            outlined = bloomed.cropped(to: edges.extent)
        }

        let canvas = CGRect(origin: .zero, size: originalSize)
        let padding: CGFloat = 8
        let clippedPrompt = prompt
            .insetBy(dx: -padding, dy: -padding)
            .intersection(canvas)
        guard !clippedPrompt.isNull,
              clippedPrompt.width > 1,
              clippedPrompt.height > 1 else {
            return outlined
        }
        return outlined
            .cropped(to: clippedPrompt)
            .transformed(by: CGAffineTransform(translationX: -clippedPrompt.minX, y: -clippedPrompt.minY))
    }

    private func prepareInputBuffer(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        // Standard resize to 1024x1024
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if width == 1024 && height == 1024 { return buffer }
        
        var resized: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1024, 1024, kCVPixelFormatType_32BGRA, nil, &resized)
        guard let output = resized else { throw SegmentationServiceError.invalidInput }
        
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let sx = 1024.0 / CGFloat(width)
        let sy = 1024.0 / CGFloat(height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(scaled, to: output)
        return output
    }

    private func convertBoxToPrompts(
        _ prompt: CGRect,
        originalSize: CGSize,
        inputImageSize: CGSize
    ) throws -> (points: MLMultiArray, labels: MLMultiArray) {
        let safeWidth = max(originalSize.width, 1)
        let safeHeight = max(originalSize.height, 1)
        var normalized = CGRect(
            x: prompt.origin.x / safeWidth,
            y: prompt.origin.y / safeHeight,
            width: prompt.size.width / safeWidth,
            height: prompt.size.height / safeHeight
        ).standardized

        let clampUnit: (CGFloat) -> CGFloat = { min(max($0, 0), 1) }
        let minX = clampUnit(normalized.minX)
        let minY = clampUnit(normalized.minY)
        let maxX = clampUnit(normalized.maxX)
        let maxY = clampUnit(normalized.maxY)
        normalized = CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0.001),
            height: max(maxY - minY, 0.001)
        )

        let scaleWidth = max(inputImageSize.width, 1)
        let scaleHeight = max(inputImageSize.height, 1)
        let scaled = CGRect(
            x: normalized.minX * scaleWidth,
            y: normalized.minY * scaleHeight,
            width: normalized.width * scaleWidth,
            height: normalized.height * scaleHeight
        )

        let points = try MLMultiArray(shape: [1, 2, 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, 2], dataType: .int32)

        points[[0, 0, 0]] = NSNumber(value: Float(scaled.minX))
        points[[0, 0, 1]] = NSNumber(value: Float(scaled.minY))
        labels[[0, 0]] = 2

        points[[0, 1, 0]] = NSNumber(value: Float(scaled.maxX))
        points[[0, 1, 1]] = NSNumber(value: Float(scaled.maxY))
        labels[[0, 1]] = 3

        return (points, labels)
    }
#endif
    
    #if canImport(CoreVideo)
    private func needsNewEmbeddings(for request: SegmentationRequest) -> Bool {
        guard cachedImageFeatures != nil else { return true }
        let fingerprint = fingerprint(for: request.pixelBuffer)
        if let lastFingerprint = lastFrameFingerprint,
           fingerprint == lastFingerprint,
           request.timestamp - lastFrameTimestamp <= stabilityInterval {
            return false
        }
        return true
    }

    private func fingerprint(for buffer: CVPixelBuffer) -> UInt64 {
        // Cheap checksum: sample the center pixel. Good enough to detect drastic scene changes.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return 0 }
        let x = width / 2
        let y = height / 2
        let offset = y * rowBytes + x
        let data = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sample = UInt64(data[offset])
        return sample
    }
    #endif
}
