import Foundation
import Utilities
#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(CoreML)
import CoreML
#endif

#if canImport(Vision)
import Vision
#endif

#if canImport(CoreML)
/// Feature provider for YOLOv8 model threshold configuration
private class YOLOThresholdProvider: NSObject, MLFeatureProvider {
    let confidenceThreshold: Double
    let iouThreshold: Double

    var featureNames: Set<String> {
        return ["iouThreshold", "confidenceThreshold"]
    }

    init(confidenceThreshold: Double, iouThreshold: Double) {
        self.confidenceThreshold = confidenceThreshold
        self.iouThreshold = iouThreshold
        super.init()
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "iouThreshold":
            return MLFeatureValue(double: iouThreshold)
        case "confidenceThreshold":
            return MLFeatureValue(double: confidenceThreshold)
        default:
            return nil
        }
    }
}
#endif

/// YOLO Interpreter backed by Core ML. If a YOLOv8 CoreML model is present in the
/// package resources (for example, "YOLOv8n.mlmodelc"), it runs real inference via Vision.
/// Otherwise it falls back to a lightweight mock that returns a single detection.
public actor YOLOInterpreter: DetectionService {
    private enum Backend {
        case mock
        #if canImport(Vision)
        case vision(model: VNCoreMLModel)
        #endif
    }

    private let logger: Logger
    private var backend: Backend = .mock
    private var maxDetections: Int = 5000
    private var isPrepared = false
    private var currentModelName: String?
    private var modelInputSize: CGSize?

    // NMS thresholds passed to the model (not client-side filtering)
    public let modelConfidenceThreshold: Double
    public let modelIouThreshold: Double

    public init(
        logger: Logger = .shared,
        confidenceThreshold: Double = 0.15,
        iouThreshold: Double = 0.35
    ) {
        self.logger = logger
        self.modelConfidenceThreshold = confidenceThreshold
        self.modelIouThreshold = iouThreshold
    }

    public func modelInputSize() async -> CGSize? {
        modelInputSize
    }

    // MARK: - Lifecycle
    public func prepare() async throws {
        guard !isPrepared else { return }

        #if canImport(Vision)
        if let modelURL = try? await locateDefaultModel() {
            do {
                try await configureVisionBackend(from: modelURL, contextLabel: "default")
                return
            } catch {
                await logger.log("Failed to load YOLO model: \(error.localizedDescription). Falling back to mock.", level: .error, category: "DetectionKit.YOLOInterpreter")
            }
        } else {
            await logger.log("No YOLOv8 .mlmodelc found in resources. Using mock backend.", level: .warning, category: "DetectionKit.YOLOInterpreter")
        }
        #else
        await logger.log("Vision/CoreML not available; using mock backend.", level: .warning, category: "DetectionKit.YOLOInterpreter")
        #endif

        isPrepared = true
    }

    public func detect(on request: DetectionRequest) async throws -> [Detection] {
        guard isPrepared else { throw DetectionError.notPrepared }

        #if canImport(CoreVideo)
        guard let pixelBuffer = request.pixelBuffer as? CVPixelBuffer else {
            throw DetectionError.invalidInput
        }
        #endif

        switch backend {
        case .mock:
            try await Task.sleep(nanoseconds: 2_000_000)
            return [
                Detection(
                    label: "MockObject",
                    confidence: 0.92,
                    boundingBox: .init(
                        origin: .init(x: 0.25, y: 0.25),
                        size: .init(width: 0.5, height: 0.5)
                    )
                )
            ]

        #if canImport(Vision)
        case let .vision(model):
            #if canImport(ImageIO)
            let orientation = request.imageOrientationRaw.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            #else
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            #endif
            let request = VNCoreMLRequest(model: model)
            // Preserve aspect ratio to avoid geometric distortion during resizing
            request.imageCropAndScaleOption = .scaleFit

            do {
                try handler.perform([request])
            } catch {
                throw DetectionError.inferenceFailed(error.localizedDescription)
            }

            let results = (request.results as? [VNRecognizedObjectObservation]) ?? []
            // Model already filtered by confidence threshold via featureProvider
            let detections = results.compactMap { obs -> Detection? in
                guard let best = obs.labels.max(by: { $0.confidence < $1.confidence }) else { return nil }
                let confidence = Double(best.confidence)
                let r = obs.boundingBox
                let normalized = NormalizedRect(
                    origin: .init(x: Double(r.origin.x), y: Double(1 - r.origin.y - r.size.height)),
                    size: .init(width: Double(r.size.width), height: Double(r.size.height))
                )
                return Detection(label: best.identifier, confidence: confidence, boundingBox: normalized)
            }

            // Memory-aware detection limit adjustment
            #if os(iOS)
            let currentLimit: Int
            if #available(iOS 15.0, *) {
                let memoryPressure = ProcessInfo.processInfo.thermalState
                switch memoryPressure {
                case .critical:
                    currentLimit = 500
                case .serious:
                    currentLimit = 2000
                default:
                    currentLimit = maxDetections
                }
            } else {
                currentLimit = maxDetections
            }
            #else
            let currentLimit = maxDetections
            #endif

            // Quality scoring: prioritize larger, more confident boxes
            // qualityScore = confidence × sqrt(boxArea)
            let scoredDetections = detections.map { detection -> (detection: Detection, score: Double) in
                let boxArea = detection.boundingBox.size.width * detection.boundingBox.size.height
                let qualityScore = detection.confidence * sqrt(boxArea)
                return (detection, qualityScore)
            }
            .sorted(by: { $0.score > $1.score })

            return scoredDetections.prefix(currentLimit).map { $0.detection }
        #endif
        }
    }

    #if canImport(Vision)
    public func loadContext(_ contextName: String) async throws {
        let canonical = canonicalContextName(contextName)
        let resourceName = "yolo_world_\(canonical)"
        if let url = try? await locateModel(named: resourceName) {
            try await configureVisionBackend(from: url, contextLabel: contextName)
            return
        }

        if canonical != "kitchen" {
            await logger.log("YOLOInterpreter: Context model '\(contextName)' missing, falling back to kitchen.", level: .warning, category: "DetectionKit.YOLOInterpreter")
            try await loadContext("kitchen")
        } else {
            await logger.log("YOLOInterpreter: Unable to load fallback kitchen model.", level: .error, category: "DetectionKit.YOLOInterpreter")
            throw DetectionError.modelNotFound
        }
    }

    private func locateDefaultModel() async throws -> URL? {
        let candidates = [
            "YOLOv8-ovd", "YOLOv8l", "YOLOv8m", "YOLOv8s", "YOLOv8", "YOLOv8n", "best", "Model"
        ]

        for name in candidates {
            if let url = try? await locateModel(named: name) {
                return url
            }
        }

        if let mock = Bundle.module.url(forResource: "MockYOLO", withExtension: "mlmodelc") {
            return mock
        }
        return nil
    }

    private func locateModel(named resourceName: String) async throws -> URL? {
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "mlmodelc") {
            return url
        }
        if let pkg = Bundle.module.url(forResource: resourceName, withExtension: "mlpackage") {
            do {
                return try await compileModelIfNeeded(pkg)
            } catch {
                await logger.log("Failed to compile \(pkg.lastPathComponent): \(error.localizedDescription)", level: .error, category: "DetectionKit.YOLOInterpreter")
            }
        }
        if let raw = Bundle.module.url(forResource: resourceName, withExtension: "mlmodel") {
            do {
                return try await compileModelIfNeeded(raw)
            } catch {
                await logger.log("Failed to compile \(raw.lastPathComponent): \(error.localizedDescription)", level: .error, category: "DetectionKit.YOLOInterpreter")
            }
        }
        return nil
    }

    private func configureVisionBackend(from modelURL: URL, contextLabel: String) async throws {
        var config = MLModelConfiguration()
        #if os(iOS)
        if #available(iOS 16.0, *) {
            config.computeUnits = .all
        }
        #endif
        let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        let visionModel = try VNCoreMLModel(for: mlModel)

        let thresholdProvider = YOLOThresholdProvider(
            confidenceThreshold: modelConfidenceThreshold,
            iouThreshold: modelIouThreshold
        )
        visionModel.featureProvider = thresholdProvider

        if let imageInput = mlModel.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key {
            visionModel.inputImageFeatureName = imageInput
            if let constraint = mlModel.modelDescription.inputDescriptionsByName[imageInput]?.imageConstraint {
                modelInputSize = CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
            }
        }

        backend = .vision(model: visionModel)
        currentModelName = contextLabel
        isPrepared = true
        await logger.log("YOLOInterpreter: Loaded model '\(contextLabel)' (\(modelURL.lastPathComponent))", level: .info, category: "DetectionKit.YOLOInterpreter")
    }

    private func canonicalContextName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private func compileModelIfNeeded(_ url: URL) async throws -> URL {
        if url.pathExtension == "mlmodelc" {
            return url
        }
        return try await MLModel.compileModel(at: url)
    }
    #endif
}
