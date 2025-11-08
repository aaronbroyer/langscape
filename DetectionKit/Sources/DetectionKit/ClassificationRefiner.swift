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

/// Optional second-stage classifier to refine YOLO labels on-device.
/// If no compatible CoreML image classification model is bundled, this is a no-op.
public struct ClassificationRefiner: @unchecked Sendable {
    public enum Error: Swift.Error { case modelNotFound }

    #if canImport(Vision)
    private let model: VNCoreMLModel
    private let ciContext = CIContext(options: nil)
    private let logger: Logger
    private let confidenceGate: Double
    
    public init(bundle: Bundle? = nil, logger: Logger = .shared, confidenceGate: Double = 0.70) throws {
        self.logger = logger
        self.confidenceGate = confidenceGate
        let resourceBundle = bundle ?? Bundle.module
        guard let url = ClassificationRefiner.locateModel(in: resourceBundle) else {
            throw Error.modelNotFound
        }
        let ml = try MLModel(contentsOf: url)
        self.model = try VNCoreMLModel(for: ml)
        Task { await logger.log("Loaded classifier for refinement: \(url.lastPathComponent)", level: .info, category: "DetectionKit.Refiner") }
    }

    /// Returns detections with labels optionally refined by the classifier.
    public func refine(_ detections: [Detection], pixelBuffer: CVPixelBuffer, orientationRaw: UInt32?) -> [Detection] {
        guard !detections.isEmpty else { return detections }
        var refined: [Detection] = []
        refined.reserveCapacity(detections.count)

        #if canImport(ImageIO)
        let orientation = orientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        #else
        let orientation: CGImagePropertyOrientation = .up
        #endif

        let W = Double(CVPixelBufferGetWidth(pixelBuffer))
        let H = Double(CVPixelBufferGetHeight(pixelBuffer))
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)

        for det in detections {
            // Convert normalized top-left origin rect to pixel coordinates
            let x = det.boundingBox.origin.x * W
            let y = det.boundingBox.origin.y * H
            let w = det.boundingBox.size.width * W
            let h = det.boundingBox.size.height * H
            let rect = CGRect(x: x, y: y, width: w, height: h)
            guard rect.width >= 10, rect.height >= 10 else { refined.append(det); continue }

            let ciCrop = baseImage.cropped(to: rect)
            guard let cg = ciContext.createCGImage(ciCrop, from: ciCrop.extent) else { refined.append(det); continue }

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            let request = VNCoreMLRequest(model: model)
            do {
                try handler.perform([request])
                if let res = request.results as? [VNClassificationObservation], let best = res.first, Double(best.confidence) >= confidenceGate {
                    let newLabel = normalize(best.identifier)
                    let confPct = Int(best.confidence * 100)
                    if newLabel.lowercased() != det.label.lowercased() {
                        let merged = Detection(id: det.id, label: newLabel, confidence: max(det.confidence, Double(best.confidence)), boundingBox: det.boundingBox)
                        refined.append(merged)
                        Task { await logger.log("Refined label \(det.label) -> \(newLabel) (\(confPct)%)", level: .debug, category: "DetectionKit.Refiner") }
                        continue
                    }
                }
            } catch {
                // fall through with original detection
            }
            refined.append(det)
        }
        return refined
    }

    private static func locateModel(in bundle: Bundle) -> URL? {
        // Look for a generic image classification model. Replace names as needed.
        let candidates = [
            "OVDClassifier", "MobileNetV3", "MobileNet", "EfficientNetLite", "Classifier"
        ]
        for name in candidates {
            if let url = bundle.url(forResource: name, withExtension: "mlmodelc") { return url }
            if let pkg = bundle.url(forResource: name, withExtension: "mlpackage") { return pkg }
        }
        return nil
    }
    
    private func normalize(_ label: String) -> String {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = Self.aliases[key] { return mapped }
        return key
    }
    
    private static let aliases: [String: String] = [
        "sofa": "couch", "tvmonitor": "tv", "tv monitor": "tv", "television": "tv",
        "cellphone": "cell phone", "mobile phone": "cell phone", "diningtable": "dining table",
        "pottedplant": "potted plant", "laptop computer": "laptop", "cup of coffee": "cup"
    ]
    #else
    public init(bundle: Bundle? = nil, logger: Logger = .shared, confidenceGate: Double = 0.70) throws { throw Error.modelNotFound }
    public func refine(_ detections: [Detection], pixelBuffer: AnyObject, orientationRaw: UInt32?) -> [Detection] { detections }
    #endif
}
