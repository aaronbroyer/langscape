import Foundation
import Utilities

#if canImport(CoreML)
import CoreML
#endif

public actor YOLOInterpreter: DetectionService {
    private var isPrepared = false
    private let logger: Logger
    private let mockDetections: [Detection]

    public init(logger: Logger = .shared) {
        self.logger = logger
        self.mockDetections = [
            Detection(
                label: "MockObject",
                confidence: 0.92,
                boundingBox: .init(
                    origin: .init(x: 0.25, y: 0.25),
                    size: .init(width: 0.5, height: 0.5)
                )
            )
        ]
    }

    public func prepare() async throws {
        guard !isPrepared else { return }

        #if canImport(CoreML)
        guard let modelURL = Bundle.module.url(forResource: "MockYOLO", withExtension: "mlmodelc") else {
            await logger.log("MockYOLO.mlmodelc missing from bundle.", level: .error, category: "DetectionKit.YOLOInterpreter")
            throw DetectionError.modelNotFound
        }

        do {
            let resourceValues = try modelURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else {
                throw DetectionError.modelLoadFailed("Resource is not a compiled model directory.")
            }
            await logger.log("Located stub CoreML bundle at \(modelURL.lastPathComponent).", level: .debug, category: "DetectionKit.YOLOInterpreter")
        } catch let error as DetectionError {
            await logger.log(error.errorDescription, level: .error, category: "DetectionKit.YOLOInterpreter")
            throw error
        } catch {
            await logger.log("Failed to access CoreML bundle: \(error.localizedDescription)", level: .error, category: "DetectionKit.YOLOInterpreter")
            throw DetectionError.modelLoadFailed(error.localizedDescription)
        }
        #else
        await logger.log("CoreML not available; running interpreter in stub mode.", level: .warning, category: "DetectionKit.YOLOInterpreter")
        #endif

        isPrepared = true
        await logger.log("YOLOInterpreter prepared (stub mode).", level: .info, category: "DetectionKit.YOLOInterpreter")
    }

    public func detect(on request: DetectionRequest) async throws -> [Detection] {
        guard isPrepared else { throw DetectionError.notPrepared }

        #if canImport(CoreVideo)
        guard request.pixelBuffer is CVPixelBuffer else {
            throw DetectionError.invalidInput
        }
        #endif

        try await Task.sleep(nanoseconds: 3_000_000) // ~3ms simulated latency

        await logger.log(
            "Returning \(mockDetections.count) mock detections for frame \(request.id).",
            level: .debug,
            category: "DetectionKit.YOLOInterpreter"
        )

        return mockDetections.map { detection in
            Detection(
                label: detection.label,
                confidence: detection.confidence,
                boundingBox: detection.boundingBox
            )
        }
    }
}
