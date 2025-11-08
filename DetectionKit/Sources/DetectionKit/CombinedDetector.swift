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
        // VLM-first: ULTRA-AGGRESSIVE settings for maximum detection of thousands of objects
        // VERY low acceptGate (0.30) for maximum recall - accept even marginal proposals
        // Very high maxProposals (3000) for dense coverage
        // cropSize: 256 to match MobileCLIP input requirements
        self.vlm = VLMDetector(logger: logger, cropSize: 256, acceptGate: 0.30, maxProposals: 3000)
        // YOLO as fallback with moderate thresholds for debugging
        self.yolo = YOLOInterpreter(logger: logger, confidenceThreshold: 0.25, iouThreshold: 0.45)
        self.filter = DetectionFilter()
        // Initialize VLM referee with relaxed gates for verification
        self.referee = try? VLMReferee(logger: logger, cropSize: 256, acceptGate: 0.60, minKeepGate: 0.40, maxProposals: 48)
        self.refereeReady = (referee != nil)
    }

    public func prepare() async throws {
        // Guard against redundant preparation calls
        guard !vlmReady && !yoloReady else {
            let vlm = vlmReady
            let yolo = yoloReady
            await logger.log("CombinedDetector: Already prepared (VLM: \(vlm), YOLO: \(yolo)), skipping", level: .debug, category: "DetectionKit.CombinedDetector")
            return
        }

        await logger.log("CombinedDetector: Starting prepare()", level: .info, category: "DetectionKit.CombinedDetector")

        // Try VLM first
        if !vlmReady {
            do {
                await logger.log("CombinedDetector: Preparing VLM...", level: .info, category: "DetectionKit.CombinedDetector")
                try await vlm.prepare()
                vlmReady = true
                await logger.log("CombinedDetector: ✅ VLM READY", level: .info, category: "DetectionKit.CombinedDetector")
            } catch {
                vlmReady = false
                await logger.log("CombinedDetector: ❌ VLM prepare FAILED: \(error)", level: .error, category: "DetectionKit.CombinedDetector")
            }
        }

        // Always try YOLO as a fallback/augmenter
        if !yoloReady {
            do {
                await logger.log("CombinedDetector: Preparing YOLO...", level: .info, category: "DetectionKit.CombinedDetector")
                try await yolo.prepare()
                yoloReady = true
                await logger.log("CombinedDetector: ✅ YOLO READY", level: .info, category: "DetectionKit.CombinedDetector")
            } catch {
                yoloReady = false
                await logger.log("CombinedDetector: ❌ YOLO prepare FAILED: \(error)", level: .error, category: "DetectionKit.CombinedDetector")
            }
        }

        let vlmStatus = vlmReady
        let yoloStatus = yoloReady
        await logger.log("CombinedDetector: Prepare complete - VLM: \(vlmStatus), YOLO: \(yoloStatus)", level: .info, category: "DetectionKit.CombinedDetector")

        if !vlmReady && !yoloReady {
            throw DetectionError.modelNotFound
        }
    }

    public func detect(on request: DetectionRequest) async throws -> [Detection] {
        var results: [Detection] = []
        results.reserveCapacity(5000)

        let vlmStatus = vlmReady
        let yoloStatus = yoloReady
        let refereeStatus = refereeReady
        await logger.log("CombinedDetector: Starting detection - VLM ready: \(vlmStatus), YOLO ready: \(yoloStatus), Referee ready: \(refereeStatus)", level: .info, category: "DetectionKit.CombinedDetector")

        // Phase 1: VLM-first detection (primary detector for open-vocabulary)
        var vlmDetections: [Detection] = []
        if vlmReady {
            await logger.log("CombinedDetector: Attempting VLM detection...", level: .info, category: "DetectionKit.CombinedDetector")
            do {
                vlmDetections = try await vlm.detect(on: request)
                let count = vlmDetections.count
                await logger.log("CombinedDetector: VLM returned \(count) detections", level: .info, category: "DetectionKit.CombinedDetector")
                results.append(contentsOf: vlmDetections)
            } catch {
                await logger.log("CombinedDetector: VLM detect failed (\(error)).", level: .error, category: "DetectionKit.CombinedDetector")
            }
        } else {
            await logger.log("CombinedDetector: VLM NOT READY - skipping VLM detection", level: .error, category: "DetectionKit.CombinedDetector")
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

        // Phase 4: Final NMS and sort (VERY loose to preserve detections)
        let beforeNMS = results.count
        results = nms(results, iou: 0.75)  // Very loose - allow heavy overlap
        results.sort { $0.confidence > $1.confidence }

        let finalCount = results.count
        await logger.log("CombinedDetector: Before NMS: \(beforeNMS), After NMS: \(finalCount), Returning \(finalCount) final detections", level: .info, category: "DetectionKit.CombinedDetector")

        // Log detection breakdown for debugging
        let labels = results.prefix(20).map { "\($0.label)(\(Int($0.confidence*100))%)" }.joined(separator: ", ")
        await logger.log("CombinedDetector: Top 20 detections: \(labels)", level: .info, category: "DetectionKit.CombinedDetector")

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

