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
        self.vlm = VLMDetector(logger: logger)
        // Use new high-recall thresholds (0.15 confidence, 0.35 IoU)
        self.yolo = YOLOInterpreter(logger: logger, confidenceThreshold: 0.15, iouThreshold: 0.35)
        self.filter = DetectionFilter()
        // Initialize VLM referee for verification
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

        // Phase 1: Run YOLO with high recall (0.15 threshold)
        var yoloDetections: [Detection] = []
        if yoloReady {
            do {
                yoloDetections = try await yolo.detect(on: request)
                let count = yoloDetections.count
                await logger.log("CombinedDetector: YOLO returned \(count) detections", level: .debug, category: "DetectionKit.CombinedDetector")
            } catch {
                await logger.log("CombinedDetector: YOLO detect failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
                // Fall back to VLM-only if YOLO fails
                if vlmReady {
                    do {
                        let vlmDets = try await vlm.detect(on: request)
                        return vlmDets.sorted { $0.confidence > $1.confidence }
                    } catch {
                        await logger.log("CombinedDetector: VLM detect also failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
                        return []
                    }
                }
                return []
            }
        } else if vlmReady {
            // YOLO not ready, fall back to VLM-only
            do {
                let vlmDets = try await vlm.detect(on: request)
                return vlmDets.sorted { $0.confidence > $1.confidence }
            } catch {
                await logger.log("CombinedDetector: VLM detect failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
                return []
            }
        } else {
            throw DetectionError.modelNotFound
        }

        // Phase 2: Apply detection filter to triage
        let filtered = filter.filter(yoloDetections)
        await logger.log("CombinedDetector: Filtered into \(filtered.autoAccept.count) high-conf, \(filtered.needsVerification.count) mid-conf, \(filtered.requiresStrictGate.count) low-conf", level: .debug, category: "DetectionKit.CombinedDetector")

        // Phase 3: Auto-accept high-confidence detections (>0.60)
        results.append(contentsOf: filtered.autoAccept)

        // Phase 4: VLM verification for mid/low confidence detections
        if refereeReady, let referee = referee {
            #if canImport(CoreVideo)
            if let pixelBuffer = request.pixelBuffer as? CVPixelBuffer {
                // Combine mid and low-confidence detections for verification
                let toVerify = filtered.needsVerification + filtered.requiresStrictGate

                if !toVerify.isEmpty {
                    // Use batch filtering with adaptive gates and early stopping
                    let verified = referee.filterBatch(
                        toVerify,
                        pixelBuffer: pixelBuffer,
                        orientationRaw: request.imageOrientationRaw,
                        minConf: 0.15,  // Verify detections >= 0.15 confidence
                        maxConf: 0.70,  // Don't re-verify high confidence (already in autoAccept)
                        maxVerify: 1000,  // Max detections to verify before early stopping
                        earlyStopThreshold: 3000  // If we have 3000+ kept, stop verifying
                    )
                    results.append(contentsOf: verified)
                } else {
                    // No detections to verify
                }
            } else {
                // No pixel buffer available, accept mid-confidence, drop low
                results.append(contentsOf: filtered.needsVerification)
            }
            #else
            // CoreVideo not available, accept mid-confidence, drop low
            results.append(contentsOf: filtered.needsVerification)
            #endif
        } else {
            // VLM referee not available, accept mid-confidence, drop low-confidence
            results.append(contentsOf: filtered.needsVerification)
            let msg = "VLM referee not available, accepting \(filtered.needsVerification.count) mid-conf, dropping \(filtered.requiresStrictGate.count) low-conf"
            await logger.log(msg, level: .debug, category: "DetectionKit.CombinedDetector")
        }

        // Phase 5: Final NMS and sort
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

