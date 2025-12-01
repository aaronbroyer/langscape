import Foundation
import Utilities
import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics

public struct SegmentationRequest {
    public let pixelBuffer: CVPixelBuffer
    public let prompt: CGRect // Normalized 0-1
    public let timestamp: TimeInterval
    public let imageSize: CGSize

    public init(pixelBuffer: CVPixelBuffer, prompt: CGRect, imageSize: CGSize, timestamp: TimeInterval = 0) {
        self.pixelBuffer = pixelBuffer
        self.prompt = prompt
        self.timestamp = timestamp
        self.imageSize = imageSize
    }
}

@available(macOS 15.0, iOS 17.0, *)
public actor SegmentationService {
    public static let shared = SegmentationService()
    private let logger: Logger

    private let encoderConfig: MLModelConfiguration
    private let promptConfig: MLModelConfiguration
    private let decoderConfig: MLModelConfiguration

    private var encoder: MLModel?
    private var promptEncoder: MLModel?
    private var decoder: MLModel?

    private let ciContext = CIContext()
    private let targetSize = CGSize(width: 1024, height: 1024)
    
    private var cachedEmbedding: MLMultiArray?
    private var cachedFeatsS0: MLMultiArray?
    private var cachedFeatsS1: MLMultiArray?
    private var lastFrameTimestamp: TimeInterval = -1

    public init(logger: Logger = .shared) {
        self.logger = logger
        
        self.encoderConfig = MLModelConfiguration()
        self.encoderConfig.computeUnits = .all

        self.promptConfig = MLModelConfiguration()
        self.promptConfig.computeUnits = .cpuOnly

        self.decoderConfig = MLModelConfiguration()
        self.decoderConfig.computeUnits = .all
    }

    public func prepare() async throws {
        if encoder != nil { return }
        let bundle = Bundle.module
        
        self.encoder = try loadModel("SAM2_1SmallImageEncoderFLOAT16", bundle, encoderConfig)
        self.promptEncoder = try loadModel("SAM2_1SmallPromptEncoderFLOAT16", bundle, promptConfig)
        self.decoder = try loadModel("SAM2_1SmallMaskDecoderFLOAT16", bundle, decoderConfig)
        
        await logger.log("✅ SAM 2.1 Models Loaded (Padding + CPU Fix Applied)", level: .info, category: "Segmentation")
    }

    public func segment(_ request: SegmentationRequest) async throws -> CIImage {
        if encoder == nil { try await prepare() }
        
        let resizedBuffer = try resizeBuffer(request.pixelBuffer, to: targetSize)
        
        if request.timestamp != lastFrameTimestamp {
            try runImageEncoder(resizedBuffer)
            lastFrameTimestamp = request.timestamp
        }
        
        guard let embedding = cachedEmbedding, let s0 = cachedFeatsS0, let s1 = cachedFeatsS1 else {
            throw NSError(domain: "Segmentation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Embedding failed"])
        }

        let (points, labels) = try makePrompts(from: request.prompt, originalSize: request.imageSize)
        let (sparse, dense) = try runPromptEncoder(points: points, labels: labels)

        let maskLogits = try runMaskDecoder(embedding: embedding, s0: s0, s1: s1, sparse: sparse, dense: dense)
        
        return try processMask(logits: maskLogits, prompt: request.prompt, imageSize: request.imageSize)
    }
    
    private func loadModel(_ name: String, _ bundle: Bundle, _ config: MLModelConfiguration) throws -> MLModel {
        if let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
            return try MLModel(contentsOf: url, configuration: config)
        }
        if let url = bundle.url(forResource: name, withExtension: "mlpackage") {
            return try MLModel(contentsOf: try MLModel.compileModel(at: url), configuration: config)
        }
        throw NSError(domain: "Segmentation", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model \(name) not found"])
    }

    private func runImageEncoder(_ buffer: CVPixelBuffer) throws {
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let output = try encoder!.prediction(from: input)
        self.cachedEmbedding = output.featureValue(for: "image_embedding")?.multiArrayValue
        self.cachedFeatsS0 = output.featureValue(for: "feats_s0")?.multiArrayValue
        self.cachedFeatsS1 = output.featureValue(for: "feats_s1")?.multiArrayValue
    }
    
    private func makePrompts(from box: CGRect, originalSize: CGSize) throws -> (MLMultiArray, MLMultiArray) {
        let scaleX = 1024.0 / originalSize.width
        let scaleY = 1024.0 / originalSize.height
        
        let x1 = Float(box.minX * originalSize.width * scaleX)
        let y1 = Float(box.minY * originalSize.height * scaleY)
        
        let x2 = Float(box.maxX * originalSize.width * scaleX)
        let y2 = Float(box.maxY * originalSize.height * scaleY)

        let count = 5
        let points = try MLMultiArray(shape: [1, NSNumber(value: count), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        
        for i in 0..<count {
            labels[[0, NSNumber(value: i)]] = -1
            points[[0, NSNumber(value: i), 0]] = 0
            points[[0, NSNumber(value: i), 1]] = 0
        }
        
        points[[0, 0, 0]] = NSNumber(value: x1)
        points[[0, 0, 1]] = NSNumber(value: y1)
        labels[[0, 0]] = 2
        
        points[[0, 1, 0]] = NSNumber(value: x2)
        points[[0, 1, 1]] = NSNumber(value: y2)
        labels[[0, 1]] = 3
        
        return (points, labels)
    }

    private func runPromptEncoder(points: MLMultiArray, labels: MLMultiArray) throws -> (MLMultiArray, MLMultiArray) {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: points),
            "labels": MLFeatureValue(multiArray: labels)
        ])
        let output = try promptEncoder!.prediction(from: input)
        return (
            output.featureValue(for: "sparse_embeddings")!.multiArrayValue!,
            output.featureValue(for: "dense_embeddings")!.multiArrayValue!
        )
    }
    
    private func runMaskDecoder(embedding: MLMultiArray, s0: MLMultiArray, s1: MLMultiArray, sparse: MLMultiArray, dense: MLMultiArray) throws -> MLMultiArray {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": MLFeatureValue(multiArray: embedding),
            "feats_s0": MLFeatureValue(multiArray: s0),
            "feats_s1": MLFeatureValue(multiArray: s1),
            "sparse_embedding": MLFeatureValue(multiArray: sparse),
            "dense_embedding": MLFeatureValue(multiArray: dense)
        ])
        let output = try decoder!.prediction(from: input)
        return output.featureValue(for: "low_res_masks")!.multiArrayValue!
    }
    
    private func processMask(logits: MLMultiArray, prompt: CGRect, imageSize: CGSize) throws -> CIImage {
        let mask256 = try logitsToImage(logits: logits)
        let upscale = mask256.transformed(by: CGAffineTransform(scaleX: 4.0, y: 4.0))

        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = upscale
        threshold.threshold = 0.0

        let gradient = CIFilter.morphologyGradient()
        gradient.inputImage = threshold.outputImage
        gradient.radius = 2.5

        guard let outline = gradient.outputImage else { return upscale }

        let contrast = outline.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputContrastKey: 1.8, kCIInputBrightnessKey: 0.1, kCIInputSaturationKey: 0.0]
        )

        let alphaMask = contrast.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0.3333, y: 0.3333, z: 0.3333, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ]
        )

        let glow = alphaMask
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4.0])
            .cropped(to: outline.extent)

        let combined = alphaMask.applyingFilter(
            "CISourceOverCompositing",
            parameters: [kCIInputBackgroundImageKey: glow]
        )

        let cropRect = CGRect(
            x: prompt.minX * 1024,
            y: (1 - prompt.maxY) * 1024,
            width: prompt.width * 1024,
            height: prompt.height * 1024
        )

        return combined.cropped(to: cropRect)
    }
    
    private func logitsToImage(logits: MLMultiArray) throws -> CIImage {
        let ptr = UnsafePointer<Float>(OpaquePointer(logits.dataPointer))
        let count = 256 * 256
        var pixels = [UInt8](repeating: 0, count: count)
        
        for i in 0..<count {
            if ptr[i] > 0.0 { pixels[i] = 255 }
        }
        
        let data = Data(pixels)
        return CIImage(bitmapData: data, bytesPerRow: 256, size: CGSize(width: 256, height: 256), format: .L8, colorSpace: nil)
    }
    
    private func resizeBuffer(_ buffer: CVPixelBuffer, to size: CGSize) throws -> CVPixelBuffer {
        var newBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &newBuffer)
        guard let output = newBuffer else { throw NSError(domain: "Segmentation", code: -1) }
        
        let ci = CIImage(cvPixelBuffer: buffer)
        let sx = size.width / CGFloat(CVPixelBufferGetWidth(buffer))
        let sy = size.height / CGFloat(CVPixelBufferGetHeight(buffer))
        let transformed = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(transformed, to: output)
        return output
    }
}
