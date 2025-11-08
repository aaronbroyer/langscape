import Foundation
import Utilities

public actor CombinedDetector: DetectionService {
    private let logger: Utilities.Logger
    private let vlm: VLMDetector
    private let yolo: YOLOInterpreter
    private var vlmReady = false
    private var yoloReady = false

    public init(logger: Utilities.Logger = .shared) {
        self.logger = logger
        self.vlm = VLMDetector(logger: logger)
        self.yolo = YOLOInterpreter(logger: logger, confidenceThreshold: 0.30, iouThreshold: 0.45)
    }

    public func prepare() async throws {
        // Try VLM first
        do {
            try await vlm.prepare()
            vlmReady = true
            await logger.log("CombinedDetector: VLM ready", level: .info, category: "DetectionKit.CombinedDetector")
        } catch {
            await logger.log("CombinedDetector: VLM prepare failed (\(error)). Will try YOLO.", level: .warning, category: "DetectionKit.CombinedDetector")
        }
        // Always try YOLO as a fallback/augmenter
        do {
            try await yolo.prepare()
            yoloReady = true
            await logger.log("CombinedDetector: YOLO ready", level: .info, category: "DetectionKit.CombinedDetector")
        } catch {
            await logger.log("CombinedDetector: YOLO prepare failed (\(error)).", level: .warning, category: "DetectionKit.CombinedDetector")
        }

        if !vlmReady && !yoloReady {
            throw DetectionError.modelNotFound
        }
    }

    public func detect(on request: DetectionRequest) async throws -> [Detection] {
        var results: [Detection] = []
        results.reserveCapacity(16)

        if vlmReady {
            do {
                let dets = try await vlm.detect(on: request)
                results.append(contentsOf: dets)
            } catch {
                await logger.log("CombinedDetector: VLM detect failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
            }
        }

        // If VLM found few results, augment with YOLO proposals (DetectionVM will run referee/refiner later)
        if yoloReady && results.count < 4 {
            do {
                let yoloDets = try await yolo.detect(on: request)
                results.append(contentsOf: yoloDets)
            } catch {
                await logger.log("CombinedDetector: YOLO detect failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
            }
        }

        // De-dup (IoU NMS-like merge) and sort
        results = nms(results, iou: 0.4)
        results.sort { $0.confidence > $1.confidence }
        return results
    }

    private func nms(_ dets: [Detection], iou: Double) -> [Detection] {
        var out: [Detection] = []
        for d in dets {
            var keep = true
            for e in out {
                if iouNorm(d.boundingBox, e.boundingBox) >= iou {
                    keep = false
                    break
                }
            }
            if keep { out.append(d) }
        }
        return out
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
}

