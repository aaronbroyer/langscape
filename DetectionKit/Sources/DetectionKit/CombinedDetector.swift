import Foundation
import Utilities

#if canImport(CoreVideo)
import CoreVideo
#endif

public actor CombinedDetector: DetectionService {
    private let logger: Utilities.Logger
    private let vlm: VLMDetector
    private let yolo: YOLOInterpreter
    private let filter: DetectionFilter
    private let referee: VLMReferee?
    private var vlmReady = false
    private var yoloReady = false
    private var refereeReady = false

    public init(logger: Utilities.Logger = .shared) {
        self.logger = logger
        // VLM-first: use high maxProposals for dense coverage of thousands of objects
        // Lower acceptGate to 0.80 for better recall while maintaining quality
        self.vlm = VLMDetector(logger: logger, cropSize: 224, acceptGate: 0.80, maxProposals: 500)
        // YOLO as minimal fallback (high-recall thresholds)
        self.yolo = YOLOInterpreter(logger: logger, confidenceThreshold: 0.15, iouThreshold: 0.35)
        self.filter = DetectionFilter()
        // Initialize VLM referee for verification of YOLO detections
        self.referee = try? VLMReferee(logger: logger, cropSize: 224, acceptGate: 0.85, minKeepGate: 0.70, maxProposals: 48)
        self.refereeReady = (referee != nil)
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
        results.reserveCapacity(5000)

        // Phase 1: VLM-first detection (primary detector for open-vocabulary)
        var vlmDetections: [Detection] = []
        if vlmReady {
            do {
                vlmDetections = try await vlm.detect(on: request)
                let count = vlmDetections.count
                await logger.log("CombinedDetector: VLM returned \(count) detections", level: .info, category: "DetectionKit.CombinedDetector")
                results.append(contentsOf: vlmDetections)
            } catch {
                await logger.log("CombinedDetector: VLM detect failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
            }
        }

        // Phase 2: Augment with YOLO only if VLM found very few results
        // YOLO provides dense coverage but limited vocabulary
        if yoloReady && results.count < 10 {
            do {
                let yoloDetections = try await yolo.detect(on: request)
                let count = yoloDetections.count
                await logger.log("CombinedDetector: Augmenting with YOLO (\(count) detections)", level: .debug, category: "DetectionKit.CombinedDetector")

                // Filter YOLO detections through VLM referee for verification
                if refereeReady, let referee = referee {
                    #if canImport(CoreVideo)
                    if let pixelBuffer = request.pixelBuffer as? CVPixelBuffer {
                        let verified = referee.filterBatch(
                            yoloDetections,
                            pixelBuffer: pixelBuffer,
                            orientationRaw: request.imageOrientationRaw,
                            minConf: 0.15,
                            maxConf: 1.0,  // Verify all YOLO detections
                            maxVerify: 500,  // Limit YOLO augmentation
                            earlyStopThreshold: 5000
                        )
                        results.append(contentsOf: verified)
                        await logger.log("CombinedDetector: Added \(verified.count) verified YOLO detections", level: .debug, category: "DetectionKit.CombinedDetector")
                    }
                    #endif
                } else {
                    // No referee, apply basic filtering
                    let filtered = filter.filter(yoloDetections)
                    // Only accept high-confidence YOLO detections without VLM verification
                    results.append(contentsOf: filtered.autoAccept)
                }
            } catch {
                await logger.log("CombinedDetector: YOLO augmentation failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
            }
        }

        // Phase 3: If both models failed, throw error
        if results.isEmpty && !vlmReady && !yoloReady {
            throw DetectionError.modelNotFound
        }

        // Phase 4: Final NMS and sort
        results = nms(results, iou: 0.4)
        results.sort { $0.confidence > $1.confidence }

        let finalCount = results.count
        await logger.log("CombinedDetector: Returning \(finalCount) final detections", level: .info, category: "DetectionKit.CombinedDetector")
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

