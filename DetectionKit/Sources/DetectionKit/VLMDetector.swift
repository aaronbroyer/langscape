import Foundation
import Utilities

#if canImport(CoreML)
import CoreML
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(ImageIO)
import ImageIO
#endif

/// VLM-first open-vocabulary detector using MobileCLIP.
/// Generates proposals from a coarse multi-scale grid and labels via CLIP similarity to a label bank.
public actor VLMDetector: DetectionService {
    private let logger: Utilities.Logger
    private let cropSize: Int
    private let acceptGate: Double
    private let maxProposals: Int
    private var prepared = false

    #if canImport(CoreML)
    private var textModel: MLModel?
    private var imageModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var labelBank: [String] = []
    private var textEmbeddings: [[Double]] = []
    private let ciContext = CIContext()
    #endif

    public init(logger: Utilities.Logger = .shared, cropSize: Int = 224, acceptGate: Double = 0.85, maxProposals: Int = 64) {
        self.logger = logger
        self.cropSize = cropSize
        self.acceptGate = acceptGate
        self.maxProposals = maxProposals
    }

    public func prepare() async throws {
        guard !prepared else { return }
        #if canImport(CoreML)
        let bundle = Bundle.module
        // Prefer MobileCLIP S2 > S1 > B > BLT > S0
        guard let (tURL, iURL) = locateMobileCLIP(in: bundle) else {
            await logger.log("MobileCLIP not found in resources", level: .error, category: "DetectionKit.VLMDetector")
            throw DetectionError.modelNotFound
        }
        do {
            self.textModel = try MLModel(contentsOf: tURL)
            self.imageModel = try MLModel(contentsOf: iURL)
            self.tokenizer = CLIPTokenizer(bundle: bundle)
        } catch {
            throw DetectionError.modelLoadFailed(error.localizedDescription)
        }
        guard let tokenizer else { throw DetectionError.modelLoadFailed("Tokenizer failed to init") }
        // Load large label bank if present; else default smaller bank
        let bankURL = bundle.url(forResource: "labelbank_en_large", withExtension: "txt") ?? bundle.url(forResource: "labelbank_en", withExtension: "txt")
        guard let url = bankURL, let txt = try? String(contentsOf: url) else {
            throw DetectionError.modelLoadFailed("label bank file missing")
        }
        let labels = txt
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var pairs: [(String, [Double])] = []
        pairs.reserveCapacity(labels.count)
        if let tModel = textModel {
            for l in labels {
                if let emb = Self.embedText(label: l, tokenizer: tokenizer, model: tModel) { pairs.append((l, emb)) }
            }
        }
        self.labelBank = pairs.map { $0.0 }
        self.textEmbeddings = pairs.map { $0.1 }
        let preparedCount = self.labelBank.count
        await logger.log("VLMDetector prepared: labels=\(preparedCount)", level: .info, category: "DetectionKit.VLMDetector")
        #else
        throw DetectionError.modelNotFound
        #endif
        prepared = true
    }

    public func detect(on request: DetectionRequest) async throws -> [Detection] {
        guard prepared else { throw DetectionError.notPrepared }
        #if canImport(CoreVideo)
        guard let pixelBuffer = request.pixelBuffer as? CVPixelBuffer else { throw DetectionError.invalidInput }
        #endif
        #if canImport(CoreML)
        guard let imageModel, !labelBank.isEmpty else { return [] }
        let W = Double(CVPixelBufferGetWidth(pixelBuffer))
        let H = Double(CVPixelBufferGetHeight(pixelBuffer))
        #if canImport(ImageIO)
        let orientation = request.imageOrientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        #else
        let orientation: CGImagePropertyOrientation = .up
        #endif
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        // Multi-scale grid proposals
        var rects: [CGRect] = []
        let scales: [Double] = [0.20, 0.25, 0.33]
        for s in scales {
            let bw = W * s
            let bh = H * s
            let strideX = bw * 0.5
            let strideY = bh * 0.5
            var y: Double = 0
            while y + bh <= H {
                var x: Double = 0
                while x + bw <= W {
                    rects.append(CGRect(x: x, y: y, width: bw, height: bh))
                    x += strideX
                }
                y += strideY
            }
        }
        if rects.count > maxProposals { rects = Array(rects.prefix(maxProposals)) }
        var out: [Detection] = []
        out.reserveCapacity(rects.count)
        for r in rects {
            guard r.width >= 12, r.height >= 12 else { continue }
            let (label, sim) = scoreLabelBank(base: baseImage, rect: r, imageModel: imageModel)
            if sim >= acceptGate {
                let nr = toNormalized(r, frameW: W, frameH: H)
                let det = Detection(label: label, confidence: sim, boundingBox: nr)
                // NMS vs what we've already added
                if out.allSatisfy({ iouNorm($0.boundingBox, det.boundingBox) < 0.4 }) {
                    out.append(det)
                }
            }
        }
        return out.sorted { $0.confidence > $1.confidence }
        #else
        return []
        #endif
    }

    #if canImport(CoreML)
    private func locateMobileCLIP(in bundle: Bundle) -> (text: URL, image: URL)? {
        for v in ["s2", "s1", "b", "blt", "s0"] {
            let txtName = "mobileclip_\(v)_text"
            let imgName = "mobileclip_\(v)_image"
            if let txt = bundle.url(forResource: txtName, withExtension: "mlpackage"),
               let img = bundle.url(forResource: imgName, withExtension: "mlpackage") { return (txt, img) }
        }
        return nil
    }

    // MARK: - CLIP helpers
    private static func embedText(label: String, tokenizer: CLIPTokenizer, model: MLModel) -> [Double]? {
        let tokens = tokenizer.encodeFull("a photo of a \(label)")
        guard let textArray = try? MLMultiArray(shape: [1, NSNumber(value: tokenizer.contextLength)], dataType: .int32) else { return nil }
        for (i, t) in tokens.enumerated() { textArray[[0, NSNumber(value: i)]] = NSNumber(value: Int32(t)) }
        do {
            let tInputs = model.modelDescription.inputDescriptionsByName
            let tKey = tInputs.first(where: { $0.value.type == MLFeatureType.multiArray })?.key ?? tInputs.first!.key
            let tOutputs = model.modelDescription.outputDescriptionsByName
            let oKey = tOutputs.first(where: { $0.value.type == MLFeatureType.multiArray })?.key ?? tOutputs.first!.key
            let prov = try MLDictionaryFeatureProvider(dictionary: [tKey: MLFeatureValue(multiArray: textArray)])
            let out = try model.prediction(from: prov)
            guard let arr = out.featureValue(for: oKey)?.multiArrayValue else { return nil }
            return l2norm(toDoubles(arr))
        } catch { return nil }
    }

    private func scoreLabelBank(base: CIImage, rect: CGRect, imageModel: MLModel) -> (String, Double) {
        let crop = base.cropped(to: rect)
        let scaleX = CGFloat(cropSize) / crop.extent.width
        let scaleY = CGFloat(cropSize) / crop.extent.height
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cg = ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: cropSize, height: cropSize)) else { return ("", 0.0) }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cropSize, cropSize, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixel = pb else { return ("", 0.0) }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: cropSize, height: cropSize, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        guard let imgVec = VLMDetector.embedImage(pixel: pixel, model: imageModel) else { return ("", 0.0) }
        var bestIdx = 0
        var bestSim = -1.0
        for (i, tv) in textEmbeddings.enumerated() {
            let sim = VLMDetector.cosine01(imgVec, tv)
            if sim > bestSim { bestSim = sim; bestIdx = i }
        }
        return (labelBank[bestIdx], bestSim)
    }

    private static func embedImage(pixel: CVPixelBuffer, model: MLModel) -> [Double]? {
        do {
            let iInputs = model.modelDescription.inputDescriptionsByName
            let iKey = iInputs.first(where: { $0.value.type == MLFeatureType.image })?.key ?? iInputs.first!.key
            let iOutputs = model.modelDescription.outputDescriptionsByName
            let oKey = iOutputs.first(where: { $0.value.type == MLFeatureType.multiArray })?.key ?? iOutputs.first!.key
            let prov = try MLDictionaryFeatureProvider(dictionary: [iKey: MLFeatureValue(pixelBuffer: pixel)])
            let out = try model.prediction(from: prov)
            guard let arr = out.featureValue(for: oKey)?.multiArrayValue else { return nil }
            return l2norm(toDoubles(arr))
        } catch { return nil }
    }

    private static func toDoubles(_ m: MLMultiArray) -> [Double] {
        var out = [Double](repeating: 0, count: m.count)
        switch m.dataType {
        case .double: for i in 0..<m.count { out[i] = m[i].doubleValue }
        case .float32, .float16: for i in 0..<m.count { out[i] = Double(truncating: m[i]) }
        default: for i in 0..<m.count { out[i] = m[i].doubleValue }
        }
        return out
    }

    private static func l2norm(_ v: [Double]) -> [Double] {
        var sum = 0.0
        for x in v { sum += x*x }
        let d = max(sqrt(sum), 1e-9)
        return v.map { $0 / d }
    }

    private static func cosine01(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        var dot = 0.0
        for i in 0..<n { dot += a[i]*b[i] }
        return max(0.0, min(1.0, 0.5 * (dot + 1.0)))
    }

    private func toNormalized(_ r: CGRect, frameW: Double, frameH: Double) -> NormalizedRect {
        return NormalizedRect(
            origin: .init(x: Double(r.origin.x) / frameW, y: Double(r.origin.y) / frameH),
            size: .init(width: Double(r.size.width) / frameW, height: Double(r.size.height) / frameH)
        )
    }

    private func iouNorm(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let ax2 = a.origin.x + a.size.width
        let ay2 = a.origin.y + a.size.height
        let bx2 = b.origin.x + b.size.width
        let by2 = b.origin.y + b.size.height
        let ix = max(0, min(ax2, bx2) - max(a.origin.x, b.origin.x))
        let iy = max(0, min(ay2, by2) - max(a.origin.y, b.origin.y))
        let inter = ix * iy
        let areaA = a.size.width * a.size.height
        let areaB = b.size.width * b.size.height
        let uni = max(areaA + areaB - inter, 1e-9)
        return inter / uni
    }
    #endif
}
