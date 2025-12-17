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

#if canImport(CoreVideo)
import CoreVideo
#endif

public struct RefereeResponse: Codable, Equatable {
    public let description: String
    public let tags: [String]
}

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
    private let labelBank: [String]?
    private let textEmbeddings: [[Double]]?
    private let isMobileCLIP: Bool
    private let ciContext = CIContext()
    private let logger: Utilities.Logger
    private let cropSize: Int
    private let acceptGate: Double
    private let minKeepGate: Double
    private let maxProposals: Int
    private let geminiAPIKey: String?

    public init(bundle: Bundle? = nil, logger: Utilities.Logger = .shared, cropSize: Int = 256, acceptGate: Double = 0.85, minKeepGate: Double = 0.70, maxProposals: Int = 48, geminiAPIKey: String? = nil) throws {
        let resourceBundle = bundle ?? Bundle.module
        self.logger = logger
        self.cropSize = cropSize
        self.acceptGate = acceptGate
        self.minKeepGate = minKeepGate
        self.maxProposals = maxProposals
        self.geminiAPIKey = geminiAPIKey

        // Prepare locals for one-time assignment to lets
        var localModel: MLModel? = nil
        var localImageFeature: String? = nil
        var localTextFeature: String? = nil
        var localOutputFeature: String? = nil
        var localYesKey: String? = nil

        var localClipText: MLModel? = nil
        var localClipImage: MLModel? = nil
        var localClipTokenizer: CLIPTokenizer? = nil
        var localLabelBank: [String]? = nil
        var localTextEmbeddings: [[Double]]? = nil
        var localIsMobileCLIP = false
        var pendingLogs: [(String, Utilities.Logger.Level, String)] = []

        // Try MobileCLIP (preferred if present). Walk variants until one loads.
        let clipVariants = ["s2", "s1", "b", "blt", "s0"]
        variantLoop: for variant in clipVariants {
            guard let (txtURL, imgURL) = VLMReferee.locateMobileCLIP(in: resourceBundle, variant: variant) else { continue }

            do {
                localClipText = try VLMReferee.loadModel(at: txtURL, logger: logger, label: "MobileCLIP text \(variant)")
            } catch {
                pendingLogs.append(("Failed to load MobileCLIP text \(variant): \(error.localizedDescription)", .error, "DetectionKit.VLMReferee"))
                continue
            }

            do {
                localClipImage = try VLMReferee.loadModel(at: imgURL, logger: logger, label: "MobileCLIP image \(variant)")
            } catch {
                pendingLogs.append(("Failed to load MobileCLIP image \(variant): \(error.localizedDescription)", .error, "DetectionKit.VLMReferee"))
                localClipText = nil
                continue
            }

            localClipTokenizer = CLIPTokenizer(bundle: resourceBundle)
            if localClipTokenizer == nil {
                pendingLogs.append(("Failed to load CLIP tokenizer (merges/vocab missing?)", .error, "DetectionKit.VLMReferee"))
                localClipText = nil
                localClipImage = nil
                continue
            }

            localIsMobileCLIP = true
            pendingLogs.append(("Loaded MobileCLIP referee variant: \(variant)", .info, "DetectionKit.VLMReferee"))

            // Preload label bank and compute text embeddings for fast per-frame scoring
            // Prefer the large bank for vocabulary coverage; fall back to curated if missing
            let bankURL = resourceBundle.url(forResource: "labelbank_en_large", withExtension: "txt")
                ?? resourceBundle.url(forResource: "labelbank_en_curated", withExtension: "txt")
                ?? resourceBundle.url(forResource: "labelbank_en", withExtension: "txt")
            if let url = bankURL, let txt = try? String(contentsOf: url) {
                let labels = txt
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if let tModel = localClipText, let tok = localClipTokenizer {
                    var pairs: [(String, [Double])] = []
                    pairs.reserveCapacity(labels.count)
                    for label in labels {
                        if let emb = Self.embedText(label: label, tokenizer: tok, model: tModel) {
                            pairs.append((label, emb))
                        }
                    }
                    localLabelBank = pairs.map { $0.0 }
                    localTextEmbeddings = pairs.map { $0.1 }
                    let preparedCount = pairs.count
                    pendingLogs.append(("Prepared \(preparedCount) VLM label embeddings", .info, "DetectionKit.VLMReferee"))
                }
            }

            break variantLoop
        }

        if !localIsMobileCLIP {
            pendingLogs.append(("MobileCLIP not found or failed to load; will try single-model VLM", .warning, "DetectionKit.VLMReferee"))
        }

        // Fallback to single‑model VLM packaged as one CoreML bundle
        if !localIsMobileCLIP {
            if let url = VLMReferee.locateSingleModel(in: resourceBundle) {
                do {
                    let mdl = try VLMReferee.loadModel(at: url, logger: logger, label: "VLM referee")
                    localModel = mdl
                    let inputs = mdl.modelDescription.inputDescriptionsByName
                    let outputs = mdl.modelDescription.outputDescriptionsByName
                    if let (k, _) = inputs.first(where: { $0.value.type == MLFeatureType.image }) { localImageFeature = k } else { pendingLogs.append(("Single-model VLM missing image input", .error, "DetectionKit.VLMReferee")) }
                    if let (k, _) = inputs.first(where: { $0.value.type == MLFeatureType.string }) { localTextFeature = k } else { pendingLogs.append(("Single-model VLM missing text input", .error, "DetectionKit.VLMReferee")) }
                    if let (k, _) = outputs.first(where: { $0.value.type == MLFeatureType.double }) {
                        localOutputFeature = k
                        localYesKey = nil
                    } else if let (k, _) = outputs.first(where: { $0.value.type == MLFeatureType.dictionary }) {
                        localOutputFeature = k
                        localYesKey = "yes"
                    } else {
                        pendingLogs.append(("Single-model VLM missing usable output", .error, "DetectionKit.VLMReferee"))
                    }
                    pendingLogs.append(("Loaded VLM referee: \(url.lastPathComponent)", .info, "DetectionKit.VLMReferee"))
                } catch {
                    pendingLogs.append(("Failed to load single-model VLM: \(error.localizedDescription)", .error, "DetectionKit.VLMReferee"))
                }
            } else {
                pendingLogs.append(("No VLM referee model found in bundle", .error, "DetectionKit.VLMReferee"))
            }
        }

        // One-time assignment to immutable properties
        self.model = localModel
        self.imageFeature = localImageFeature
        self.textFeature = localTextFeature
        self.outputFeature = localOutputFeature
        self.yesKey = localYesKey
        self.clipTextModel = localClipText
        self.clipImageModel = localClipImage
        self.clipTokenizer = localClipTokenizer
        self.labelBank = localLabelBank
        self.textEmbeddings = localTextEmbeddings
        self.isMobileCLIP = localIsMobileCLIP

        // Emit logs now that initialization is complete
        for (msg, lvl, cat) in pendingLogs {
            Task { await logger.log(msg, level: lvl, category: cat) }
        }

        // Surface a hard failure if nothing was loaded
        if !localIsMobileCLIP && localModel == nil {
            throw Error.modelNotFound
        }
    }

    #if canImport(CoreVideo)
    public func adjudicate(image: CVPixelBuffer, objectName: String) async throws -> RefereeResponse {
        guard let apiKey = geminiAPIKey, !apiKey.isEmpty else {
            throw DetectionError.modelNotFound
        }
        guard let base64Image = convertToBase64(pixelBuffer: image) else {
            throw DetectionError.invalidInput
        }

        let promptText = """
        Analyze this image crop. The user detects a '\(objectName)'. 1. Confirm or correct the object name. 2. Describe it in the target language using 3 adjectives (material, color, style). 3. Return strictly JSON: { "description": "...", "tags": [...] }
        """
        let jsonBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": promptText],
                        ["inline_data": ["mime_type": "image/jpeg", "data": base64Image]]
                    ]
                ]
            ]
        ]

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)") else {
            throw DetectionError.invalidInput
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw DetectionError.inferenceFailed("Gemini responded with status \(http.statusCode)")
        }
        return try parseGeminiResponse(data)
    }

    /// Filter detections with VLM verification (legacy, single-threaded)
    public func filter(_ detections: [Detection], pixelBuffer: CVPixelBuffer, orientationRaw: UInt32?, minConf: Double = 0.30, maxConf: Double = 0.70) -> [Detection] {
        guard !detections.isEmpty else { return detections }
        #if canImport(ImageIO)
        let orientation = orientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        #else
        let orientation: CGImagePropertyOrientation = .up
        #endif
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let extent = baseImage.extent
        let W = Double(extent.width)
        let H = Double(extent.height)

        var kept: [Detection] = []
        kept.reserveCapacity(detections.count)
        for det in detections {
            if det.confidence > maxConf { kept.append(det); continue }
            // Detection bounding boxes are normalized with origin at top-left (UI space),
            // while CIImage coordinates are bottom-left. Flip Y back for cropping.
            let rect = CGRect(
                x: extent.origin.x + det.boundingBox.origin.x * W,
                y: extent.origin.y + (1.0 - det.boundingBox.origin.y - det.boundingBox.size.height) * H,
                width: det.boundingBox.size.width * W,
                height: det.boundingBox.size.height * H
            ).intersection(extent)
            guard rect.width >= 10, rect.height >= 10 else { kept.append(det); continue }

            // Determine acceptance gate based on input confidence
            // Mid-confidence (0.30-0.60): relaxed gate at 0.80
            // Low-confidence (0.15-0.30): strict gate at 0.85
            let confidenceGate = det.confidence >= 0.30 ? 0.80 : acceptGate

            let (bestLabel, score) = refine(label: det.label, base: baseImage, rect: rect)
            let newLabel = (score >= confidenceGate) ? bestLabel : det.label
            let newConf = (score >= confidenceGate) ? max(det.confidence, score) : det.confidence
            if score < minKeepGate {
                // Drop boxes that the VLM strongly disagrees with to improve precision
                Task { await logger.log("VLM dropped \(det.label) (~\(Int(score*100))%)", level: .debug, category: "DetectionKit.VLMReferee") }
                continue
            } else if score < confidenceGate {
                Task { await logger.log("VLM low agreement for \(det.label) (~\(Int(score*100))%)", level: .debug, category: "DetectionKit.VLMReferee") }
            }
            kept.append(Detection(id: det.id, label: newLabel, confidence: newConf, boundingBox: det.boundingBox))
        }
        // Grid proposal generation removed for Phase 2 - trust YOLO's high recall
        return kept
    }

    /// Batch filter detections with VLM verification for improved efficiency
    /// Processes detections in batches to reduce overhead
    public func filterBatch(_ detections: [Detection], pixelBuffer: CVPixelBuffer, orientationRaw: UInt32?, minConf: Double = 0.30, maxConf: Double = 0.70, maxVerify: Int = 1000, earlyStopThreshold: Int = 3000) -> [Detection] {
        guard !detections.isEmpty else { return detections }
        #if canImport(ImageIO)
        let orientation = orientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        #else
        let orientation: CGImagePropertyOrientation = .up
        #endif
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let extent = baseImage.extent
        let W = Double(extent.width)
        let H = Double(extent.height)

        var kept: [Detection] = []
        kept.reserveCapacity(detections.count)
        var verifiedCount = 0

        for det in detections {
            // Auto-accept high confidence
            if det.confidence > maxConf {
                kept.append(det)
                continue
            }

            // Detection bounding boxes are normalized with origin at top-left (UI space),
            // while CIImage coordinates are bottom-left. Flip Y back for cropping.
            let rect = CGRect(
                x: extent.origin.x + det.boundingBox.origin.x * W,
                y: extent.origin.y + (1.0 - det.boundingBox.origin.y - det.boundingBox.size.height) * H,
                width: det.boundingBox.size.width * W,
                height: det.boundingBox.size.height * H
            ).intersection(extent)
            guard rect.width >= 10, rect.height >= 10 else {
                kept.append(det)
                continue
            }

            // Early stopping: if we've verified enough and have enough accepted detections, accept remaining high/mid confidence without verification
            if verifiedCount >= maxVerify && kept.count >= earlyStopThreshold && det.confidence >= 0.30 {
                kept.append(det)
                continue
            }

            // Determine acceptance gate based on input confidence
            // Mid-confidence (0.30-0.60): relaxed gate at 0.80
            // Low-confidence (0.15-0.30): strict gate at 0.85
            let confidenceGate = det.confidence >= 0.30 ? 0.80 : acceptGate

            let (bestLabel, score) = refine(label: det.label, base: baseImage, rect: rect)
            verifiedCount += 1

            let newLabel = (score >= confidenceGate) ? bestLabel : det.label
            let newConf = (score >= confidenceGate) ? max(det.confidence, score) : det.confidence
            if score < minKeepGate {
                // Drop boxes that the VLM strongly disagrees with to improve precision
                Task { await logger.log("VLM dropped \(det.label) (~\(Int(score*100))%)", level: .debug, category: "DetectionKit.VLMReferee") }
                continue
            } else if score < confidenceGate {
                Task { await logger.log("VLM low agreement for \(det.label) (~\(Int(score*100))%)", level: .debug, category: "DetectionKit.VLMReferee") }
            }
            kept.append(Detection(id: det.id, label: newLabel, confidence: newConf, boundingBox: det.boundingBox))
        }

        let msg = "VLM verified \(verifiedCount) detections, kept \(kept.count)"
        Task { await logger.log(msg, level: .info, category: "DetectionKit.VLMReferee") }
        return kept
    }

    private func refine(label: String, base: CIImage, rect: CGRect) -> (String, Double) {
        let crop = base.cropped(to: rect)
        let scaleX = CGFloat(cropSize) / crop.extent.width
        let scaleY = CGFloat(cropSize) / crop.extent.height
        let scaled = crop.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cg = ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: cropSize, height: cropSize)) else { return (label, 0.5) }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cropSize, cropSize, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixel = pb else { return (label, 0.5) }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: cropSize, height: cropSize, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cropSize, height: cropSize))
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)

        if isMobileCLIP, let clipTextModel, let clipImageModel, let clipTokenizer {
            // Use CLIP in two ways:
            // 1) Binary confirmation of the YOLO label (fallback if no label bank)
            // 2) If a label bank is available, pick best-matching label and boost confidence
            if let bank = labelBank, let tEmb = textEmbeddings {
                if let imgVec = Self.embedImage(pixel: pixel, model: clipImageModel) {
                    // Cosine sim → [0,1]
                    var bestIdx = 0
                    var bestSim = -1.0
                    for (i, tv) in tEmb.enumerated() {
                        let sim = Self.cosine01(imgVec, tv)
                        if sim > bestSim { bestSim = sim; bestIdx = i }
                    }
                    let topLabel = bank[bestIdx]
                    let sim = bestSim
                    // Keep/Relabel policy: if similarity is strong, relabel and boost conf
                    if sim >= acceptGate {
                        return (topLabel, sim)
                    }
                    // Else fall back to binary prompt on the original label
                    return (label, scoreMobileCLIP(label: label, pixel: pixel, textModel: clipTextModel, imageModel: clipImageModel, tokenizer: clipTokenizer))
                }
            }
            return (label, scoreMobileCLIP(label: label, pixel: pixel, textModel: clipTextModel, imageModel: clipImageModel, tokenizer: clipTokenizer))
        }
        
        guard let model, let imageFeature, let textFeature else { return (label, 0.5) }
        let prompt = "a photo of a \(label)"
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                imageFeature: MLFeatureValue(pixelBuffer: pixel),
                textFeature: MLFeatureValue(string: prompt)
            ])
            let out = try model.prediction(from: provider)
            if let key = outputFeature, let val = out.featureValue(for: key)?.doubleValue { return (label, max(0.0, min(1.0, val))) }
            if let key = outputFeature, let dict = out.featureValue(for: key)?.dictionaryValue as? [String: NSNumber] {
                if let k = yesKey, let v = dict[k]?.doubleValue { return (label, v) }
                return (label, dict.values.map { $0.doubleValue }.max() ?? 0.5)
            }
        } catch {
            Task { await logger.log("VLM prediction failed: \(error.localizedDescription)", level: .error, category: "DetectionKit.VLMReferee") }
            return (label, 0.5)
        }
        return (label, 0.5)
    }

    // MARK: - Grid proposals with CLIP
    private func proposeFromGrid(base: CIImage, frameW: Double, frameH: Double, existing: [NormalizedRect], bank: [String], textEmb: [[Double]], imageModel: MLModel) -> [Detection] {
        // Multi-scale coarse grid: prefer medium/small boxes
        let scales: [Double] = [0.25, 0.33]
        var rects: [CGRect] = []
        for s in scales {
            let bw = frameW * s
            let bh = frameH * s
            let strideX = bw * 0.5
            let strideY = bh * 0.5
            var y: Double = 0
            while y + bh <= frameH { var x: Double = 0; while x + bw <= frameW {
                rects.append(CGRect(x: x, y: y, width: bw, height: bh))
                x += strideX
            }; y += strideY }
        }
        // Limit candidates
        if rects.count > maxProposals { rects = Array(rects.prefix(maxProposals)) }
        var added: [Detection] = []
        added.reserveCapacity(rects.count)
        for r in rects {
            guard r.width >= 10, r.height >= 10 else { continue }
            // Skip if overlaps an existing detection significantly
            let nr = toNormalized(r, frameW: frameW, frameH: frameH)
            var overlaps = false
            for e in existing { if iouNorm(nr, e) >= 0.4 { overlaps = true; break } }
            if overlaps { continue }
            // Score with CLIP
            let (label, sim) = scoreLabelBank(base: base, rect: r, bank: bank, textEmb: textEmb, imageModel: imageModel)
            if sim >= max(acceptGate, 0.75) {
                let det = Detection(label: label, confidence: sim, boundingBox: nr)
                // NMS vs what we've already added
                if added.allSatisfy({ iouNorm($0.boundingBox, nr) < 0.4 }) {
                    added.append(det)
                }
            }
        }
        if !added.isEmpty {
            let proposalsCount = added.count
            Task { await logger.log("VLM proposals added: \(proposalsCount)", level: .info, category: "DetectionKit.VLMReferee") }
        }
        return added
    }

    private func scoreLabelBank(base: CIImage, rect: CGRect, bank: [String], textEmb: [[Double]], imageModel: MLModel) -> (String, Double) {
        // Crop and embed image
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

        guard let imgVec = Self.embedImage(pixel: pixel, model: imageModel) else { return ("", 0.0) }
        var bestIdx = 0
        var bestSim = -1.0
        for (i, tv) in textEmb.enumerated() {
            let sim = Self.cosine01(imgVec, tv)
            if sim > bestSim { bestSim = sim; bestIdx = i }
        }
        return (bank[bestIdx], bestSim)
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

    private func mergeDetections(_ base: [Detection], with add: [Detection]) -> [Detection] {
        guard !add.isEmpty else { return base }
        var out = base
        for d in add {
            if out.allSatisfy({ iouNorm($0.boundingBox, d.boundingBox) < 0.4 }) {
                out.append(d)
            }
        }
        return out.sorted { $0.confidence > $1.confidence }
    }

    private func convertToBase64(pixelBuffer: CVPixelBuffer) -> String? {
        #if canImport(CoreImage)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let data = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) {
            return data.base64EncodedString()
        }
        #endif
        return nil
    }
    #endif

    private func parseGeminiResponse(_ data: Data) throws -> RefereeResponse {
        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                    }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(GeminiResponse.self, from: data)
        guard let rawText = payload.candidates.first?.content.parts.compactMap({ $0.text }).first else {
            throw DetectionError.inferenceFailed("Gemini returned no text response")
        }
        let jsonString = sanitizeJSONBlock(rawText)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw DetectionError.inferenceFailed("Unable to encode Gemini JSON")
        }
        do {
            return try decoder.decode(RefereeResponse.self, from: jsonData)
        } catch {
            throw DetectionError.inferenceFailed("Failed to decode referee JSON: \(error.localizedDescription)")
        }
    }

    private func sanitizeJSONBlock(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("```") {
            output = output.replacingOccurrences(of: "```json", with: "")
            output = output.replacingOccurrences(of: "```", with: "")
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private static func locateSingleModel(in bundle: Bundle) -> URL? {
        let candidates = ["MobileVLM", "MobileVLMInt8", "VLMReferee", "OVDClassifier"]
        for name in candidates {
            if let url = bundle.url(forResource: name, withExtension: "mlpackage") { return url }
            if let url = bundle.url(forResource: name, withExtension: "mlmodelc") { return url }
        }
        return nil
    }

    private static func locateMobileCLIP(in bundle: Bundle, variant: String) -> (text: URL, image: URL)? {
        let txtName = "mobileclip_\(variant)_text"
        let imgName = "mobileclip_\(variant)_image"

        if let txt = bundle.url(forResource: txtName, withExtension: "mlmodelc"),
           let img = bundle.url(forResource: imgName, withExtension: "mlmodelc") {
            return (txt, img)
        }

        if let txt = bundle.url(forResource: txtName, withExtension: "mlpackage"),
           let img = bundle.url(forResource: imgName, withExtension: "mlpackage") {
            return (txt, img)
        }

        #if DEBUG
        if let resourcePath = bundle.resourcePath {
            print("VLMReferee: MobileCLIP variant \(variant) not found in bundle resources at \(resourcePath)")
        }
        #endif
        return nil
    }

    private static func loadModel(at url: URL, logger: Utilities.Logger, label: String) throws -> MLModel {
        let compiledURL: URL
        if url.pathExtension == "mlmodelc" {
            compiledURL = url
        } else {
            do {
                compiledURL = try MLModel.compileModel(at: url)
            } catch {
                Task { await logger.log("Failed to compile \(label) \(url.lastPathComponent): \(error.localizedDescription)", level: .error, category: "DetectionKit.VLMReferee") }
                throw error
            }
        }

        do {
            return try MLModel(contentsOf: compiledURL)
        } catch {
            Task { await logger.log("Failed to load \(label) \(compiledURL.lastPathComponent): \(error.localizedDescription)", level: .error, category: "DetectionKit.VLMReferee") }
            throw error
        }
    }
    #else
    public init(bundle: Bundle? = nil, logger: Utilities.Logger = .shared, cropSize: Int = 224, acceptGate: Double = 0.7) throws { throw Error.modelNotFound }
    #endif
}

#if canImport(CoreML)
import Accelerate
extension VLMReferee {
    // MARK: - Embedding helpers
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
            let tInputKey = tInputs.first(where: { $0.value.type == MLFeatureType.multiArray })?.key ?? tInputs.first!.key
            let tOutputs = textModel.modelDescription.outputDescriptionsByName
            let tOutputKey = tOutputs.first(where: { $0.value.type == MLFeatureType.multiArray })?.key ?? tOutputs.first!.key
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
            let iInputKey = iInputs.first(where: { $0.value.type == MLFeatureType.image })?.key ?? iInputs.first!.key
            let iOutputs = imageModel.modelDescription.outputDescriptionsByName
            let iOutputKey = iOutputs.first(where: { $0.value.type == MLFeatureType.multiArray })?.key ?? iOutputs.first!.key
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
