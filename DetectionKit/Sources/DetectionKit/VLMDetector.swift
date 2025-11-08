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

    public init(logger: Utilities.Logger = .shared, cropSize: Int = 256, acceptGate: Double = 0.85, maxProposals: Int = 64) {
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
        let totalLabels = labels.count
        await logger.log("VLMDetector: Found \(totalLabels) labels in bank, embedding...", level: .info, category: "DetectionKit.VLMDetector")
        var pairs: [(String, [Double])] = []
        pairs.reserveCapacity(labels.count)
        var failedCount = 0
        if let tModel = textModel {
            for l in labels {
                if let emb = Self.embedText(label: l, tokenizer: tokenizer, model: tModel) {
                    pairs.append((l, emb))
                } else {
                    failedCount += 1
                }
            }
        } else {
            await logger.log("VLMDetector: textModel is nil, cannot embed labels", level: .error, category: "DetectionKit.VLMDetector")
        }
        self.labelBank = pairs.map { $0.0 }
        self.textEmbeddings = pairs.map { $0.1 }
        let preparedCount = self.labelBank.count
        let failed = failedCount
        await logger.log("VLMDetector prepared: labels=\(preparedCount)/\(totalLabels) (failed: \(failed))", level: .info, category: "DetectionKit.VLMDetector")

        // Diagnostic: Check embedding diversity by comparing first few embeddings
        if textEmbeddings.count >= 10 {
            let sampleLabels = Array(labelBank.prefix(10))
            print("VLMDetector.prepare: Sample labels: \(sampleLabels.joined(separator: ", "))")
            // Compare first two embeddings to verify they're different
            if textEmbeddings.count >= 2 {
                let emb0 = textEmbeddings[0]
                let emb1 = textEmbeddings[1]
                let similarity = VLMDetector.cosine01(emb0, emb1)
                print("VLMDetector.prepare: Similarity between '\(labelBank[0])' and '\(labelBank[1])': \(Int(similarity*100))%")
                // Also check if embeddings are normalized
                let norm0 = sqrt(emb0.reduce(0.0) { $0 + $1*$1 })
                let norm1 = sqrt(emb1.reduce(0.0) { $0 + $1*$1 })
                print("VLMDetector.prepare: Embedding norms: '\(labelBank[0])'=\(norm0), '\(labelBank[1])'=\(norm1)")
            }
        }
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
        guard let imageModel, !labelBank.isEmpty else {
            let hasImageModel = imageModel != nil
            let bankSize = labelBank.count
            await logger.log("VLMDetector: Cannot detect - imageModel: \(hasImageModel), labelBank size: \(bankSize)", level: .error, category: "DetectionKit.VLMDetector")
            return []
        }
        let W = Double(CVPixelBufferGetWidth(pixelBuffer))
        let H = Double(CVPixelBufferGetHeight(pixelBuffer))
        #if canImport(ImageIO)
        let orientation = request.imageOrientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        #else
        let orientation: CGImagePropertyOrientation = .up
        #endif
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        // Multi-scale grid proposals - AGGRESSIVE for maximum coverage
        var rects: [CGRect] = []
        // Many scales from tiny to large objects
        let scales: [Double] = [0.08, 0.10, 0.12, 0.15, 0.18, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.60, 0.70]
        for s in scales {
            let bw = W * s
            let bh = H * s
            // Denser stride for more overlap - 0.33 instead of 0.5
            let strideX = bw * 0.33
            let strideY = bh * 0.33
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
        let totalProposals = rects.count
        await logger.log("VLMDetector: Generated \(totalProposals) grid proposals before limit", level: .info, category: "DetectionKit.VLMDetector")
        if rects.count > maxProposals {
            rects = Array(rects.prefix(maxProposals))
            await logger.log("VLMDetector: Limited to \(maxProposals) proposals", level: .info, category: "DetectionKit.VLMDetector")
        }
        var out: [Detection] = []
        out.reserveCapacity(rects.count)
        var scored = 0
        var accepted = 0
        for r in rects {
            guard r.width >= 8, r.height >= 8 else { continue }  // Allow smaller boxes
            let (label, sim) = scoreLabelBank(base: baseImage, rect: r, imageModel: imageModel)
            scored += 1
            if sim >= acceptGate {
                accepted += 1
                let nr = toNormalized(r, frameW: W, frameH: H)
                let det = Detection(label: label, confidence: sim, boundingBox: nr)
                // Very loose NMS - allow heavy overlap (0.7 instead of 0.4)
                if out.allSatisfy({ iouNorm($0.boundingBox, det.boundingBox) < 0.7 }) {
                    out.append(det)
                }
            }
        }
        let finalCount = out.count
        let scoredCount = scored
        let acceptedCount = accepted
        await logger.log("VLMDetector: Scored \(scoredCount) proposals, accepted \(acceptedCount) above gate \(acceptGate), kept \(finalCount) after NMS", level: .info, category: "DetectionKit.VLMDetector")
        return out.sorted { $0.confidence > $1.confidence }
        #else
        return []
        #endif
    }

    #if canImport(CoreML)
    private func locateMobileCLIP(in bundle: Bundle) -> (text: URL, image: URL)? {
        // Try both .mlmodelc (compiled) and .mlpackage (source) for each variant
        for v in ["s2", "s1", "b", "blt", "s0"] {
            let txtName = "mobileclip_\(v)_text"
            let imgName = "mobileclip_\(v)_image"

            // Try compiled models first (.mlmodelc)
            if let txt = bundle.url(forResource: txtName, withExtension: "mlmodelc"),
               let img = bundle.url(forResource: imgName, withExtension: "mlmodelc") {
                Task { await logger.log("VLMDetector: Found compiled MobileCLIP \(v) models", level: .info, category: "DetectionKit.VLMDetector") }
                return (txt, img)
            }

            // Try source packages (.mlpackage)
            if let txt = bundle.url(forResource: txtName, withExtension: "mlpackage"),
               let img = bundle.url(forResource: imgName, withExtension: "mlpackage") {
                Task { await logger.log("VLMDetector: Found MobileCLIP \(v) mlpackage models", level: .info, category: "DetectionKit.VLMDetector") }
                return (txt, img)
            }
        }

        // Debug: Log all available resources
        Task {
            await logger.log("VLMDetector: MobileCLIP models not found. Searching bundle resources...", level: .error, category: "DetectionKit.VLMDetector")
            if let resourcePath = bundle.resourcePath {
                await logger.log("VLMDetector: Bundle resource path: \(resourcePath)", level: .error, category: "DetectionKit.VLMDetector")
            }
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

    private var diagnosticCallCount = 0  // Add counter for diagnostic logging
    private var textEmbeddingDiagnosticDone = false  // Track if we've checked text embeddings

    private func scoreLabelBank(base: CIImage, rect: CGRect, imageModel: MLModel) -> (String, Double) {
        // First time: check text embedding diversity
        if !textEmbeddingDiagnosticDone && textEmbeddings.count >= 10 {
            textEmbeddingDiagnosticDone = true
            print("VLMDetector: TEXT EMBEDDING DIAGNOSTIC")
            print("VLMDetector: Total text embeddings: \(textEmbeddings.count)")
            print("VLMDetector: First 10 labels: \(labelBank.prefix(10).joined(separator: ", "))")

            // Check diversity: compare first embedding to several others
            let emb0 = textEmbeddings[0]
            let label0 = labelBank[0]
            for i in [1, 50, 100, 200, 500, 1000].filter({ $0 < textEmbeddings.count }) {
                let sim = VLMDetector.cosine01(emb0, textEmbeddings[i])
                print("VLMDetector: Similarity '\(label0)' vs '\(labelBank[i])': \(Int(sim*100))%")
            }

            // Check if all embeddings are suspiciously similar
            var totalSim = 0.0
            var count = 0
            for i in 1..<min(10, textEmbeddings.count) {
                totalSim += VLMDetector.cosine01(textEmbeddings[0], textEmbeddings[i])
                count += 1
            }
            let avgSim = totalSim / Double(count)
            print("VLMDetector: Average similarity of first 10 embeddings: \(Int(avgSim*100))%")
            if avgSim > 0.80 {
                print("VLMDetector: ⚠️ WARNING: Text embeddings are too similar! Average similarity \(Int(avgSim*100))% (should be <50%)")
            }
        }
        // Ensure crop rect is valid and within base image bounds
        let imageExtent = base.extent
        let clampedRect = rect.intersection(imageExtent)
        guard clampedRect.width > 0 && clampedRect.height > 0 else {
            if diagnosticCallCount <= 5 {
                print("VLMDetector.scoreLabelBank: Invalid rect - out of bounds")
            }
            return ("", 0.0)
        }

        let crop = base.cropped(to: clampedRect)
        let scaleX = CGFloat(cropSize) / crop.extent.width
        let scaleY = CGFloat(cropSize) / crop.extent.height
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Create CGImage with proper bounds
        let targetRect = CGRect(x: 0, y: 0, width: cropSize, height: cropSize)
        guard let cg = ciContext.createCGImage(scaled, from: targetRect) else {
            if diagnosticCallCount <= 5 {
                print("VLMDetector.scoreLabelBank: Failed to create CGImage from rect \(clampedRect)")
            }
            return ("", 0.0)
        }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cropSize, cropSize, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixel = pb else {
            print("VLMDetector.scoreLabelBank: Failed to create CVPixelBuffer, status=\(status)")
            return ("", 0.0)
        }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: cropSize, height: cropSize, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        guard let imgVec = VLMDetector.embedImage(pixel: pixel, model: imageModel) else {
            print("VLMDetector.scoreLabelBank: Failed to embed image")
            return ("", 0.0)
        }

        // Compute all similarities
        var scores: [(idx: Int, sim: Double)] = []
        scores.reserveCapacity(textEmbeddings.count)
        for (i, tv) in textEmbeddings.enumerated() {
            let sim = VLMDetector.cosine01(imgVec, tv)
            scores.append((i, sim))
        }
        scores.sort { $0.sim > $1.sim }

        // Diagnostic logging for first 3 proposals
        diagnosticCallCount += 1
        if diagnosticCallCount <= 3 {
            let top5 = scores.prefix(5).map { (idx, sim) in
                "\(labelBank[idx])(\(Int(sim*100))%)"
            }.joined(separator: ", ")
            print("VLMDetector.scoreLabelBank #\(diagnosticCallCount): Top-5 matches: \(top5)")
            // Check embedding diversity
            let imgNorm = imgVec.reduce(0.0) { $0 + $1*$1 }
            print("VLMDetector.scoreLabelBank #\(diagnosticCallCount): Image embedding L2 norm: \(sqrt(imgNorm))")
        }

        let bestIdx = scores[0].idx
        let bestSim = scores[0].sim
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
        } catch {
            // Log error for debugging (this is a static method, so we can't access logger actor)
            let w = CVPixelBufferGetWidth(pixel)
            let h = CVPixelBufferGetHeight(pixel)
            print("VLMDetector.embedImage failed: \(error.localizedDescription), pixel size: \(w)x\(h)")
            return nil
        }
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
