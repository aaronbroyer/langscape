import Foundation
import Utilities

#if canImport(CoreVideo)
import CoreVideo
#endif

public actor CombinedDetector: DetectionService {
    private let logger: Utilities.Logger
    private let vlm: VLMDetector?
    private let yolo: YOLOInterpreter
    private let filter: DetectionFilter
    private let referee: VLMReferee?
    private var vlmReady = false
    private var yoloReady = false
    private var refereeReady = false
    private var consecutiveEmptyDetections = 0
    private let maxEmptyDetectionsBeforeReset = 60

    public init(logger: Utilities.Logger = .shared, geminiAPIKey: String? = nil) {
        self.logger = logger
        // YOLO-FIRST ARCHITECTURE: Fast, proven, object-aware detection
        // YOLO is the primary detector with high recall settings
        self.yolo = YOLOInterpreter(logger: logger, confidenceThreshold: 0.15, iouThreshold: 0.35)
        self.filter = DetectionFilter()

        // VLM Referee: VERIFICATION ONLY (not proposal generation)
        // Used to filter out obvious false positives and improve label precision.
        do {
            let r = try VLMReferee(logger: logger, cropSize: 256, acceptGate: 0.80, minKeepGate: 0.55, maxProposals: 64, geminiAPIKey: geminiAPIKey)
            self.referee = r
            self.refereeReady = true
        } catch {
            self.referee = nil
            self.refereeReady = false
            Task { await logger.log("CombinedDetector: ⚠️ Failed to init VLM Referee (\(error.localizedDescription)); YOLO-only mode", level: .error, category: "DetectionKit.CombinedDetector") }
        }

        // VLM Detector: DISABLED for MVP (grid proposals too slow and inaccurate)
        // Can re-enable later for open-vocabulary expansion
        self.vlm = nil
        self.vlmReady = false
    }

    public func prepare() async throws {
        // Guard against redundant preparation calls
        guard !yoloReady else {
            await logger.log("CombinedDetector: Already prepared (YOLO-first mode), skipping", level: .debug, category: "DetectionKit.CombinedDetector")
            return
        }

        await logger.log("CombinedDetector: Starting prepare() - YOLO-FIRST ARCHITECTURE", level: .info, category: "DetectionKit.CombinedDetector")

        // Prepare YOLO (primary detector)
        if !yoloReady {
            do {
                await logger.log("CombinedDetector: Preparing YOLO (primary detector)...", level: .info, category: "DetectionKit.CombinedDetector")
                try await yolo.prepare()
                yoloReady = true
                await logger.log("CombinedDetector: ✅ YOLO READY (primary)", level: .info, category: "DetectionKit.CombinedDetector")
            } catch {
                yoloReady = false
                await logger.log("CombinedDetector: ❌ YOLO prepare FAILED: \(error)", level: .error, category: "DetectionKit.CombinedDetector")
                throw DetectionError.modelNotFound
            }
        }

        // VLM Referee initialized during init() - no async preparation needed
        let refereeStatus = refereeReady
        if refereeStatus {
            await logger.log("CombinedDetector: ✅ VLM REFEREE loaded (verification layer)", level: .info, category: "DetectionKit.CombinedDetector")
        } else {
            await logger.log("CombinedDetector: ⚠️ VLM Referee not available (YOLO-only mode)", level: .warning, category: "DetectionKit.CombinedDetector")
        }

        await logger.log("CombinedDetector: Prepare complete - YOLO: ✅, VLM Referee: \(refereeStatus ? "✅" : "⚠️ disabled")", level: .info, category: "DetectionKit.CombinedDetector")
    }

    public func loadContext(_ contextName: String) async -> Bool {
        await logger.log("CombinedDetector: Loading context '\(contextName)'", level: .info, category: "DetectionKit.CombinedDetector")
        do {
            try await yolo.loadContext(contextName)
            yoloReady = true
            return true
        } catch {
            await logger.log("CombinedDetector: Failed to load context '\(contextName)': \(error.localizedDescription)", level: .error, category: "DetectionKit.CombinedDetector")
            return false
        }
    }

    public func detect(on request: DetectionRequest) async throws -> [Detection] {
        guard yoloReady else {
            throw DetectionError.notPrepared
        }

        await logger.log("CombinedDetector: Starting detection - YOLO-FIRST mode", level: .info, category: "DetectionKit.CombinedDetector")

        // Phase 1: YOLO Detection (PRIMARY - fast, proven, object-aware)
        let yoloDetections: [Detection]
        do {
            yoloDetections = try await yolo.detect(on: request)
            let count = yoloDetections.count
            await logger.log("CombinedDetector: YOLO returned \(count) raw detections", level: .info, category: "DetectionKit.CombinedDetector")
        } catch {
            await logger.log("CombinedDetector: YOLO detection FAILED: \(error)", level: .error, category: "DetectionKit.CombinedDetector")
            throw error
        }

        guard !yoloDetections.isEmpty else {
            consecutiveEmptyDetections += 1
            await logger.log("CombinedDetector: No YOLO detections found", level: .warning, category: "DetectionKit.CombinedDetector")
            if consecutiveEmptyDetections >= maxEmptyDetectionsBeforeReset {
                consecutiveEmptyDetections = 0
                await logger.log("CombinedDetector: YOLO returned 0 detections for \(maxEmptyDetectionsBeforeReset) consecutive frames – re-preparing model.", level: .warning, category: "DetectionKit.CombinedDetector")
                yoloReady = false
                do {
                    try await yolo.prepare()
                    yoloReady = true
                    await logger.log("CombinedDetector: YOLO successfully re-prepared after zero-detection streak.", level: .info, category: "DetectionKit.CombinedDetector")
                } catch {
                    await logger.log("CombinedDetector: Failed to re-prepare YOLO after zero-detection streak: \(error.localizedDescription)", level: .error, category: "DetectionKit.CombinedDetector")
                }
            }
            return []
        }

        consecutiveEmptyDetections = 0

        // Phase 2: Filter and Bucket YOLO detections
        let filtered = filter.filter(yoloDetections)
        let autoAccepted = filtered.autoAccept
        let candidates = filtered.needsVerification + filtered.requiresStrictGate
        let candidatesForVerification = Array(
            candidates
                .sorted(by: { qualityScore($0) > qualityScore($1) })
                .prefix(16)
        )
        let needsVerifyCount = candidatesForVerification.count
        let autoAcceptCount = autoAccepted.count
        await logger.log(
            "CombinedDetector: Candidate detections after filter: \(filtered.all.count) (auto-accept \(autoAcceptCount), verifying \(needsVerifyCount))",
            level: .info,
            category: "DetectionKit.CombinedDetector"
        )

        var results: [Detection] = []
        results.reserveCapacity(autoAcceptCount + needsVerifyCount)
        results.append(contentsOf: autoAccepted)

        // Phase 3: VLM Referee Verification (for uncertain detections only)
        if refereeReady, let referee = referee, !candidatesForVerification.isEmpty {
            #if canImport(CoreVideo)
            let pixelBuffer: CVPixelBuffer = request.pixelBuffer
            await logger.log("CombinedDetector: Verifying \(candidatesForVerification.count) YOLO detections with VLM Referee", level: .info, category: "DetectionKit.CombinedDetector")
            let verified = referee.filterBatch(
                candidatesForVerification,
                pixelBuffer: pixelBuffer,
                orientationRaw: request.imageOrientationRaw,
                minConf: 0.15,
                maxConf: 0.60,  // Auto-accept high-confidence boxes
                maxVerify: 200,  // Limit verification workload
                earlyStopThreshold: 1000  // Stop when enough verified
            )
            if verified.isEmpty {
                results.append(contentsOf: candidatesForVerification)
                await logger.log("CombinedDetector: VLM Referee kept 0/\(candidatesForVerification.count); falling back to unverified YOLO candidates", level: .warning, category: "DetectionKit.CombinedDetector")
            } else {
                results.append(contentsOf: verified)
                await logger.log("CombinedDetector: VLM Referee kept \(verified.count)/\(candidatesForVerification.count) detections after verification", level: .info, category: "DetectionKit.CombinedDetector")

                let totalAvailable = autoAcceptCount + candidatesForVerification.count
                let minimumTarget = min(3, totalAvailable)
                if results.count < minimumTarget {
                    let verifiedIDs = Set(verified.map { $0.id })
                    let backfill = candidatesForVerification
                        .filter { !verifiedIDs.contains($0.id) }
                        .sorted(by: { $0.confidence > $1.confidence })
                        .prefix(minimumTarget - results.count)
                    if !backfill.isEmpty {
                        results.append(contentsOf: backfill)
                        await logger.log("CombinedDetector: Backfilled \(backfill.count) unverified YOLO detections to reach \(minimumTarget) candidates", level: .info, category: "DetectionKit.CombinedDetector")
                    }
                }
            }
            #endif
        } else {
            // No referee available - accept mid-confidence detections without verification
            let midConfDetections = candidatesForVerification.filter { $0.confidence >= 0.40 }
            results.append(contentsOf: midConfDetections)
            await logger.log("CombinedDetector: No VLM Referee - accepting \(midConfDetections.count) mid-confidence detections (≥0.40) without verification", level: .warning, category: "DetectionKit.CombinedDetector")
        }

        // Phase 4: Final NMS and sorting
        let beforeNMS = results.count
        results = nms(results, iou: 0.50)  // Standard NMS threshold
        let afterNMS = results.count
        results.sort { $0.confidence > $1.confidence }
        results = dedupeByLabel(results)

        let finalCount = results.count
        await logger.log("CombinedDetector: Pipeline complete - Before NMS: \(beforeNMS), After NMS: \(afterNMS), After label dedupe: \(finalCount)", level: .info, category: "DetectionKit.CombinedDetector")

        // Log top detections for debugging
        if !results.isEmpty {
            let topLabels = results.prefix(15).map { "\($0.label)(\(Int($0.confidence*100))%)" }.joined(separator: ", ")
            await logger.log("CombinedDetector: Top 15 detections: \(topLabels)", level: .info, category: "DetectionKit.CombinedDetector")
        }

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

    private func qualityScore(_ detection: Detection) -> Double {
        let area = max(0.0, detection.boundingBox.size.width * detection.boundingBox.size.height)
        return detection.confidence * sqrt(area)
    }

    private func dedupeByLabel(_ detections: [Detection]) -> [Detection] {
        var seen: Set<String> = []
        var out: [Detection] = []
        out.reserveCapacity(detections.count)
        for det in detections {
            let key = det.label.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(det)
        }
        return out
    }
}
