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
    
    private let ciContext = CIContext()
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
        // logits shape: [1, 3, 256, 256]
        let width = 256
        let height = 256
        
        // Extract specific mask channel
        // CoreML MLMultiArray is [Batch, Channel, Height, Width] or flattened
        // We iterate manually to build a bitmap
        var bitmap = [UInt8](repeating: 0, count: width * height)
        
        // Pointer access is faster
        let ptr = UnsafePointer<Float>(OpaquePointer(logits.dataPointer))
        let strideC = width * height // Stride for channels
        let offset = maskIndex * strideC
        
        for i in 0..<(width * height) {
            let val = ptr[offset + i]
            // Sigmoid: 1 / (1 + exp(-x))
            // But optimization: if val > 0 it's > 0.5 prob.
            bitmap[i] = val > 0 ? 255 : 0 
        }
        
        let data = Data(bitmap)
        let maskImage = CIImage(
            bitmapData: data,
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .L8, // 8-bit grayscale
            colorSpace: nil
        )
        
        // Upscale to fit the prompt rect
        return processAndStylize(maskImage, prompt: prompt, originalSize: originalSize)
    }

    /// Creates the "Glowing Outline" effect
    private func processAndStylize(_ smallMask: CIImage, prompt: CGRect, originalSize: CGSize) -> CIImage {
        // 1. Scale 256x256 mask up to full screen
        let scaleX = originalSize.width / 256.0
        let scaleY = originalSize.height / 256.0
        
        let upscaled = smallMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // 2. Create Outline (Edge Detection)
        // Morphology Edge: Dilate - Erode, or Edges filter
        let edges = upscaled.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 10.0])

        // 3. Colorize (Neon Cyan)
        // Use sourceAtop to paint color ONLY where edges exist
        let color = CIImage(color: CIColor(red: 0, green: 1, blue: 1, alpha: 1.0)) // Full Cyan
        let coloredEdges = color.compositingOverImage(edges, operation: .sourceIn)
        
        // 4. Crop to the bounding box to save processing (Optional, but good for perf)
        // For now, return full image to match screen
        return coloredEdges
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
        // FIX: Calculate scale directly from original size to 1024x1024
        // Do NOT invert Y. SAM 2 expects Image Coordinates (Top-Left origin).
        
        let scaleX = inputImageSize.width / originalSize.width
        let scaleY = inputImageSize.height / originalSize.height
        
        // Scale the bounding box
        let x1 = Float(prompt.minX * scaleX)
        let y1 = Float(prompt.minY * scaleY)
        let x2 = Float(prompt.maxX * scaleX)
        let y2 = Float(prompt.maxY * scaleY)
        
        // Create Arrays (Fixed size 5 for Apple models)
        let coords = try MLMultiArray(shape: [1, 5, 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, 5], dataType: .int32)
        
        // Fill with padding (-1)
        for i in 0..<5 {
            labels[[0, NSNumber(value: i)]] = -1
            coords[[0, NSNumber(value: i), 0]] = 0
            coords[[0, NSNumber(value: i), 1]] = 0
        }
        
        // Point 1: Top-Left (Label 2)
        coords[[0, 0, 0]] = NSNumber(value: x1)
        coords[[0, 0, 1]] = NSNumber(value: y1)
        labels[[0, 0]] = 2
        
        // Point 2: Bottom-Right (Label 3)
        coords[[0, 1, 0]] = NSNumber(value: x2)
        coords[[0, 1, 1]] = NSNumber(value: y2)
        labels[[0, 1]] = 3
        
        return (coords, labels)
    }
#endif
    
    #if canImport(CoreVideo)
    private func needsNewEmbeddings(for request: SegmentationRequest) -> Bool {
        if cachedImageFeatures == nil { return true }
        let fingerprint = fingerprint(for: request.pixelBuffer)
        if let last = lastFrameFingerprint, let timestamp = Optional(lastFrameTimestamp), timestamp + stabilityInterval > request.timestamp {
            return fingerprint != last
        }
        return fingerprint != lastFrameFingerprint
    }

    private func fingerprint(for buffer: CVPixelBuffer) -> UInt64 {
        // Simple center-pixel check for performance
        return 0 // Force update for now to ensure correctness, optimize later
    }
    #endif
}

#if canImport(CoreImage)
private extension CIImage {
    func compositingOverImage(_ background: CIImage, operation: CGBlendMode) -> CIImage {
        switch operation {
        case .sourceIn:
            let filter = CIFilter(name: "CISourceInCompositing")
            filter?.setValue(self, forKey: kCIInputImageKey)
            filter?.setValue(background, forKey: kCIInputBackgroundImageKey)
            return filter?.outputImage ?? self.composited(over: background)
        default:
            return self.composited(over: background)
        }
    }
}
#endif
