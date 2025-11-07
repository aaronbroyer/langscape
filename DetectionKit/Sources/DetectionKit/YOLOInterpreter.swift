import Foundation
import Utilities

#if canImport(CoreML)
import CoreML
#endif

#if canImport(Vision)
import Vision
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
    private var isPrepared = false

    public init(logger: Logger = .shared) {
        self.logger = logger
    }

    // MARK: - Lifecycle
    public func prepare() async throws {
        guard !isPrepared else { return }

        #if canImport(Vision)
        if let modelURL = try? await locateModel() {
            do {
                let mlModel = try MLModel(contentsOf: modelURL)
                let visionModel = try VNCoreMLModel(for: mlModel)
                // Only set inputImageFeatureName when the feature is actually an image.
                if let imageInput = mlModel.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key {
                    visionModel.inputImageFeatureName = imageInput
                }
                backend = .vision(model: visionModel)
                isPrepared = true
                await logger.log("Loaded YOLO model: \(modelURL.lastPathComponent)", level: .info, category: "DetectionKit.YOLOInterpreter")
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
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill

            do {
                try handler.perform([request])
            } catch {
                throw DetectionError.inferenceFailed(error.localizedDescription)
            }

            let results = (request.results as? [VNRecognizedObjectObservation]) ?? []
            return results.flatMap { obs -> [Detection] in
                let top = obs.labels.max(by: { $0.confidence < $1.confidence })
                guard let label = top?.identifier else { return [] }
                let confidence = Double(top?.confidence ?? 0)
                // Vision's boundingBox is normalized with origin at bottom-left.
                let r = obs.boundingBox
                let normalized = NormalizedRect(
                    origin: .init(x: Double(r.origin.x), y: Double(1 - r.origin.y - r.size.height)),
                    size: .init(width: Double(r.size.width), height: Double(r.size.height))
                )
                return [Detection(label: label, confidence: confidence, boundingBox: normalized)]
            }
        #endif
        }
    }

    #if canImport(Vision)
    private func locateModel() async throws -> URL? {
        // Search for common YOLOv8 compiled model names in the SPM module bundle.
        let candidates = [
            "YOLOv8", "YOLOv8n", "YOLOv8s", "YOLOv8m", "YOLOv8l", "best", "Model"
        ]

        for name in candidates {
            if let url = Bundle.module.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
            if let pkg = Bundle.module.url(forResource: name, withExtension: "mlpackage") {
                return pkg
            }
            // If a raw .mlmodel is included, compile it on device.
            if let raw = Bundle.module.url(forResource: name, withExtension: "mlmodel") {
                do {
                    let compiled: URL
                    if #available(iOS 18.0, macOS 15.0, *) {
                        compiled = try await MLModel.compileModel(at: raw)
                    } else {
                        compiled = try await MLModel.compileModel(at: raw)
                    }
                    return compiled
                } catch {
                    await logger.log("Failed to compile \(raw.lastPathComponent): \(error.localizedDescription)", level: .error, category: "DetectionKit.YOLOInterpreter")
                }
            }
        }

        // Fall back to the bundled mock model if present; use it only to validate resources.
        if let mock = Bundle.module.url(forResource: "MockYOLO", withExtension: "mlmodelc") {
            return mock // Still usable (produces no boxes unless converted), but at least loads.
        }
        return nil
    }
    #endif
}
