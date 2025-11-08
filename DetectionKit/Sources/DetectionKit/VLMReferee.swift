import Foundation
import Utilities

#if canImport(CoreML)
import CoreML
#endif

#if canImport(Vision)
import Vision
#endif

#if canImport(CoreImage)
import CoreImage
#endif

public struct VLMReferee: @unchecked Sendable {
    public enum Error: Swift.Error { case modelNotFound }

    #if canImport(CoreML)
    // Single‑model path (generic VLM that accepts image+string)
    private let model: MLModel?
    private let imageFeature: String?
    private let textFeature: String?
    private let outputFeature: String?
    private let yesKey: String?

    // MobileCLIP path (two encoders + tokenizer)
    private let clipTextModel: MLModel?
    private let clipImageModel: MLModel?
    private let clipTokenizer: CLIPTokenizer?
    private let isMobileCLIP: Bool
    private let ciContext = CIContext()
    private let logger: Logger
    private let cropSize: Int
    private let acceptGate: Double

    public init(bundle: Bundle? = nil, logger: Logger = .shared, cropSize: Int = 224, acceptGate: Double = 0.7) throws {
        let resourceBundle = bundle ?? Bundle.module
        self.logger = logger
        self.cropSize = cropSize
        self.acceptGate = acceptGate

        // Try MobileCLIP (preferred if present)
        if let (txtURL, imgURL) = VLMReferee.locateMobileCLIP(in: resourceBundle) {
            self.clipTextModel = try? MLModel(contentsOf: txtURL)
            self.clipImageModel = try? MLModel(contentsOf: imgURL)
            self.clipTokenizer = CLIPTokenizer(bundle: resourceBundle)
            self.isMobileCLIP = (clipTextModel != nil && clipImageModel != nil && clipTokenizer != nil)
            self.model = nil
            self.imageFeature = nil
            self.textFeature = nil
            self.outputFeature = nil
            self.yesKey = nil
            if isMobileCLIP {
                Task { await logger.log("Loaded MobileCLIP referee: \(imgURL.deletingPathExtension().lastPathComponent)", level: .info, category: "DetectionKit.VLMReferee") }
                return
            }
        } else {
            self.clipTextModel = nil
            self.clipImageModel = nil
            self.clipTokenizer = nil
            self.isMobileCLIP = false
        }

        // Fallback to single‑model VLM packaged as one CoreML bundle
        guard let url = VLMReferee.locateSingleModel(in: resourceBundle) else {
            throw Error.modelNotFound
        }
        let mdl = try MLModel(contentsOf: url)
        self.model = mdl
        let inputs = mdl.modelDescription.inputDescriptionsByName
        let outputs = mdl.modelDescription.outputDescriptionsByName
        if let (k, _) = inputs.first(where: { $0.value.type == .image }) { self.imageFeature = k } else { throw Error.modelNotFound }
        if let (k, _) = inputs.first(where: { $0.value.type == .string }) { self.textFeature = k } else { throw Error.modelNotFound }
        if let (k, _) = outputs.first(where: { $0.value.type == .double }) {
            self.outputFeature = k
            self.yesKey = nil
        } else if let (k, _) = outputs.first(where: { $0.value.type == .dictionary(keyType: .string, valueType: .double) }) {
            self.outputFeature = k
            self.yesKey = "yes"
        } else {
            self.outputFeature = nil
            self.yesKey = nil
        }
        Task { await logger.log("Loaded VLM referee: \(url.lastPathComponent)", level: .info, category: "DetectionKit.VLMReferee") }
    }

    #if canImport(CoreVideo)
    public func filter(_ detections: [Detection], pixelBuffer: CVPixelBuffer, orientationRaw: UInt32?, minConf: Double = 0.30, maxConf: Double = 0.70) -> [Detection] {
        guard !detections.isEmpty else { return detections }
        let W = Double(CVPixelBufferGetWidth(pixelBuffer))
        let H = Double(CVPixelBufferGetHeight(pixelBuffer))
        #if canImport(ImageIO)
        let orientation = orientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        #else
        let orientation: CGImagePropertyOrientation = .up
        #endif
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)

        var kept: [Detection] = []
        kept.reserveCapacity(detections.count)
        for det in detections {
            if det.confidence < minConf || det.confidence > maxConf { kept.append(det); continue }
            let rect = CGRect(x: det.boundingBox.origin.x * W, y: det.boundingBox.origin.y * H, width: det.boundingBox.size.width * W, height: det.boundingBox.size.height * H)
            guard rect.width >= 10, rect.height >= 10 else { kept.append(det); continue }
            let score = score(label: det.label, base: baseImage, rect: rect)
            if score >= acceptGate {
                kept.append(Detection(id: det.id, label: det.label, confidence: max(det.confidence, score), boundingBox: det.boundingBox))
            } else {
                Task { await logger.log("VLM filtered \(det.label) (\(Int(score*100))%)", level: .debug, category: "DetectionKit.VLMReferee") }
            }
        }
        return kept
    }

    private func score(label: String, base: CIImage, rect: CGRect) -> Double {
        let crop = base.cropped(to: rect)
        let scaleX = CGFloat(cropSize) / crop.extent.width
        let scaleY = CGFloat(cropSize) / crop.extent.height
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cg = ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: cropSize, height: cropSize)) else { return 0.5 }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cropSize, cropSize, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixel = pb else { return 0.5 }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: cropSize, height: cropSize, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)

        if isMobileCLIP, let clipTextModel, let clipImageModel, let clipTokenizer {
            return scoreMobileCLIP(label: label, pixel: pixel, textModel: clipTextModel, imageModel: clipImageModel, tokenizer: clipTokenizer)
        }

        guard let model, let imageFeature, let textFeature else { return 0.5 }
        let prompt = "a photo of a \(label)"
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                imageFeature: MLFeatureValue(pixelBuffer: pixel),
                textFeature: MLFeatureValue(string: prompt)
            ])
            let out = try model.prediction(from: provider)
            if let key = outputFeature, let val = out.featureValue(for: key)?.doubleValue { return max(0.0, min(1.0, val)) }
            if let key = outputFeature, let dict = out.featureValue(for: key)?.dictionaryValue as? [String: NSNumber] {
                if let k = yesKey, let v = dict[k]?.doubleValue { return v }
                return dict.values.map { $0.doubleValue }.max() ?? 0.5
            }
        } catch {
            Task { await logger.log("VLM prediction failed: \(error.localizedDescription)", level: .error, category: "DetectionKit.VLMReferee") }
            return 0.5
        }
        return 0.5
    }
    #endif

    private static func locateSingleModel(in bundle: Bundle) -> URL? {
        let candidates = ["MobileVLM", "MobileVLMInt8", "VLMReferee", "OVDClassifier"]
        for name in candidates {
            if let url = bundle.url(forResource: name, withExtension: "mlpackage") { return url }
            if let url = bundle.url(forResource: name, withExtension: "mlmodelc") { return url }
        }
        return nil
    }

    private static func locateMobileCLIP(in bundle: Bundle) -> (text: URL, image: URL)? {
        let variants = ["s0", "s1", "s2", "blt", "b"]
        for v in variants {
            let txtName = "mobileclip_\(v)_text"
            let imgName = "mobileclip_\(v)_image"
            if let txt = bundle.url(forResource: txtName, withExtension: "mlpackage"),
               let img = bundle.url(forResource: imgName, withExtension: "mlpackage") {
                return (txt, img)
            }
        }
        return nil
    }
    #else
    public init(bundle: Bundle? = nil, logger: Logger = .shared, cropSize: Int = 224, acceptGate: Double = 0.7) throws { throw Error.modelNotFound }
    #endif
}

#if canImport(CoreML)
import Accelerate
extension VLMReferee {
    private func scoreMobileCLIP(label: String, pixel: CVPixelBuffer, textModel: MLModel, imageModel: MLModel, tokenizer: CLIPTokenizer) -> Double {
        // Build text tokens (1 x 77)
        let prompt = "a photo of a \(label)"
        let tokens = tokenizer.encodeFull(prompt)
        guard let textArray = try? MLMultiArray(shape: [1, NSNumber(value: tokenizer.contextLength)], dataType: .int32) else { return 0.5 }
        // Fill tokens
        for (i, t) in tokens.enumerated() {
            let idx = i as NSNumber
            textArray[[0, idx]] = NSNumber(value: Int32(t))
        }

        // Run text encoder
        var textFeatures: MLMultiArray
        do {
            // Find text input/output keys
            let tInputs = textModel.modelDescription.inputDescriptionsByName
            let tInputKey = tInputs.first(where: { $0.value.type == .multiArray })?.key ?? tInputs.first!.key
            let tOutputs = textModel.modelDescription.outputDescriptionsByName
            let tOutputKey = tOutputs.first(where: { $0.value.type == .multiArray })?.key ?? tOutputs.first!.key
            let textProvider = try MLDictionaryFeatureProvider(dictionary: [tInputKey: MLFeatureValue(multiArray: textArray)])
            let tOut = try textModel.prediction(from: textProvider)
            guard let arr = tOut.featureValue(for: tOutputKey)?.multiArrayValue else { return 0.5 }
            textFeatures = arr
        } catch {
            Task { await logger.log("MobileCLIP text encode failed: \(error.localizedDescription)", level: .error, category: "DetectionKit.VLMReferee") }
            return 0.5
        }

        // Run image encoder
        var imageFeatures: MLMultiArray
        do {
            let iInputs = imageModel.modelDescription.inputDescriptionsByName
            let iInputKey = iInputs.first(where: { $0.value.type == .image })?.key ?? iInputs.first!.key
            let iOutputs = imageModel.modelDescription.outputDescriptionsByName
            let iOutputKey = iOutputs.first(where: { $0.value.type == .multiArray })?.key ?? iOutputs.first!.key
            let imgProvider = try MLDictionaryFeatureProvider(dictionary: [iInputKey: MLFeatureValue(pixelBuffer: pixel)])
            let iOut = try imageModel.prediction(from: imgProvider)
            guard let arr = iOut.featureValue(for: iOutputKey)?.multiArrayValue else { return 0.5 }
            imageFeatures = arr
        } catch {
            Task { await logger.log("MobileCLIP image encode failed: \(error.localizedDescription)", level: .error, category: "DetectionKit.VLMReferee") }
            return 0.5
        }

        // Convert to double arrays and L2 normalize
        func toDoubles(_ m: MLMultiArray) -> [Double] {
            let ptr = UnsafeMutablePointer<Double>.allocate(capacity: m.count)
            defer { ptr.deallocate() }
            var out = [Double](repeating: 0, count: m.count)
            switch m.dataType {
            case .double:
                for i in 0..<m.count { out[i] = m[i].doubleValue }
            case .float32:
                for i in 0..<m.count { out[i] = Double(truncating: m[i]) }
            case .float16:
                for i in 0..<m.count { out[i] = Double(truncating: m[i]) }
            default:
                for i in 0..<m.count { out[i] = m[i].doubleValue }
            }
            return out
        }
        let t = toDoubles(textFeatures)
        let i = toDoubles(imageFeatures)
        func l2norm(_ v: [Double]) -> [Double] {
            var sum = 0.0
            for x in v { sum += x*x }
            let d = max(sqrt(sum), 1e-9)
            return v.map { $0 / d }
        }
        let tn = l2norm(t)
        let inorm = l2norm(i)
        var dot = 0.0
        let N = min(tn.count, inorm.count)
        for k in 0..<N { dot += tn[k]*inorm[k] }
        // Map cosine similarity [-1,1] to [0,1]
        let score = 0.5 * (dot + 1.0)
        return max(0.0, min(1.0, score))
    }
}
#endif
