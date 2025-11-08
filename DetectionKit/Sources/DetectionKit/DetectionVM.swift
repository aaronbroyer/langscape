import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#else
public struct CGSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
#endif
import Utilities

#if canImport(Combine)
import Combine
#else
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Published<Value> { self }
}
#endif

@MainActor
public final class DetectionVM: ObservableObject {
    @Published public private(set) var detections: [Detection] = []
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var lastError: DetectionError?
    @Published public private(set) var inputImageSize: CGSize?

    public let throttleInterval: TimeInterval

    private let logger: Logger
    private let processor: DetectionProcessor
    private let errorStore: ErrorStore
    private var lastSubmissionDate: Date = .distantPast
    private var fpsWindowStart: Date?
    private var processedFrames = 0
    private var droppedFrames = 0
    private let fpsWindow: TimeInterval

    public init(
        service: any DetectionService,
        throttleInterval: TimeInterval = 0.06,
        fpsWindow: TimeInterval = 1,
        logger: Logger = .shared,
        errorStore: ErrorStore = .shared
    ) {
        self.throttleInterval = throttleInterval
        self.logger = logger
        self.processor = DetectionProcessor(service: service)
        self.fpsWindow = fpsWindow
        self.errorStore = errorStore
    }

    public func setInputSize(_ size: CGSize) {
        self.inputImageSize = size
    }

    public func enqueue(_ request: DetectionRequest) {
        let now = Date()
        guard now.timeIntervalSince(lastSubmissionDate) >= throttleInterval else {
            droppedFrames += 1
            let dropped = droppedFrames
            let logger = self.logger
            Task { await logger.log("Dropping frame due to throttle (total dropped: \(dropped)).", level: .debug, category: "DetectionKit.DetectionVM") }
            return
        }

        lastSubmissionDate = now
        let logger = self.logger
        let processor = self.processor
        let errorStore = self.errorStore

        Task(priority: .userInitiated) { [weak self] in
            guard let viewModel = self else { return }
            do {
                let detections = try await processor.process(request)
                await MainActor.run {
                    viewModel.detections = detections
                    viewModel.lastError = nil
                    viewModel.registerFrame(timestamp: request.timestamp)
                }
                let labels = detections.map { "\($0.label)(\(Int($0.confidence*100))%)" }.joined(separator: ", ")
                await logger.log("Processed frame \(request.id) with \(detections.count) detections: [\(labels)]", level: .debug, category: "DetectionKit.DetectionVM")
            } catch let error as DetectionError {
                await MainActor.run {
                    viewModel.lastError = error
                }
                await logger.log(error.errorDescription, level: .error, category: "DetectionKit.DetectionVM")
                await errorStore.add(
                    LoggedError(
                        message: error.errorDescription,
                        metadata: [
                            "requestID": request.id.uuidString,
                            "category": "DetectionKit.DetectionVM"
                        ]
                    )
                )
            } catch {
                await MainActor.run {
                    viewModel.lastError = .unknown(error.localizedDescription)
                }
                await logger.log("Unexpected detection error: \(error.localizedDescription)", level: .error, category: "DetectionKit.DetectionVM")
                await errorStore.add(
                    LoggedError(
                        message: error.localizedDescription,
                        metadata: [
                            "requestID": request.id.uuidString,
                            "category": "DetectionKit.DetectionVM",
                            "type": "unexpected"
                        ]
                    )
                )
            }
        }
    }

    public func registerFatalError(_ message: String, metadata: [String: String] = [:]) {
        lastError = .unknown(message)
        let combined = metadata.merging(["category": "DetectionKit.Fatal"]) { current, _ in current }
        Task { await logger.log(message, level: .error, category: "DetectionKit.Fatal") }
        Task { await errorStore.add(LoggedError(message: message, metadata: combined)) }
    }

    private func registerFrame(timestamp: Date) {
        if fpsWindowStart == nil {
            fpsWindowStart = timestamp
            processedFrames = 0
        }

        processedFrames += 1
        guard let start = fpsWindowStart else { return }
        let elapsed = timestamp.timeIntervalSince(start)
        guard elapsed >= fpsWindow else { return }

        fps = Double(processedFrames) / max(elapsed, 0.000_1)
        fpsWindowStart = timestamp
        processedFrames = 0

        let logger = self.logger
        let fpsValue = self.fps
        Task {
            let formatted = String(format: "%.2f", fpsValue)
            await logger.log("Detection FPS: \(formatted)", level: .info, category: "DetectionKit.DetectionVM")
        }
    }
}

private actor DetectionProcessor {
    private let service: any DetectionService
    private var prepared = false
    // Temporal smoothing state
    private var tracks: [UUID: Track] = [:]
    private let iouThreshold: Double = 0.40
    private let requiredHits: Int = 3
    private let maxTrackAge: TimeInterval = 0.6
    private let smoothingAlpha: Double = 0.5 // EMA for bbox/confidence

    init(service: any DetectionService) {
        self.service = service
    }

    func process(_ request: DetectionRequest) async throws -> [Detection] {
        if !prepared {
            try await service.prepare()
            prepared = true
        }
        let raw = try await service.detect(on: request)
        let stabilized = stabilize(detections: raw, timestamp: request.timestamp)
        return stabilized
    }

    // MARK: - Stabilization
    private struct Track {
        let id: UUID
        var label: String
        var labelCounts: [String: Int]
        var bbox: NormalizedRect
        var confidence: Double
        var hits: Int
        var lastTimestamp: Date
    }

    private func stabilize(detections: [Detection], timestamp: Date) -> [Detection] {
        // Step 1: Associate detections to existing tracks by IoU (label-agnostic)
        var unmatchedTrackIDs = Set(tracks.keys)

        for det in detections {
            // Find best matching track by IoU regardless of label
            var bestID: UUID?
            var bestIoU: Double = 0
            for (id, tr) in tracks {
                let iouVal = iou(tr.bbox, det.boundingBox)
                if iouVal > bestIoU { bestIoU = iouVal; bestID = id }
            }

            if let id = bestID, bestIoU >= iouThreshold, var tr = tracks[id] {
                // EMA update
                tr.bbox = emaBBox(old: tr.bbox, new: det.boundingBox, alpha: smoothingAlpha)
                tr.confidence = tr.confidence * (1 - smoothingAlpha) + det.confidence * smoothingAlpha
                tr.hits += 1
                tr.lastTimestamp = timestamp
                // Label majority voting
                let key = det.label.lowercased()
                var counts = tr.labelCounts
                counts[key, default: 0] += 1
                tr.labelCounts = counts
                if let (bestLabel, _) = counts.max(by: { $0.value < $1.value }) {
                    tr.label = bestLabel
                }
                tracks[id] = tr
                unmatchedTrackIDs.remove(id)
            } else {
                // New track
                let id = det.id
                tracks[id] = Track(
                    id: id,
                    label: det.label.lowercased(),
                    labelCounts: [det.label.lowercased(): 1],
                    bbox: det.boundingBox,
                    confidence: det.confidence,
                    hits: 1,
                    lastTimestamp: timestamp
                )
            }
        }

        // Step 2: Age/prune unmatched tracks
        for id in unmatchedTrackIDs {
            if let tr = tracks[id], timestamp.timeIntervalSince(tr.lastTimestamp) > maxTrackAge {
                tracks.removeValue(forKey: id)
            }
        }

        // Step 3: Emit stable tracks only
        let stable = tracks.values.filter { tr in
            tr.hits >= requiredHits && timestamp.timeIntervalSince(tr.lastTimestamp) <= maxTrackAge
        }
        .sorted(by: { $0.confidence > $1.confidence })

        return stable.map { tr in
            Detection(id: tr.id, label: tr.label, confidence: tr.confidence, boundingBox: tr.bbox)
        }
    }

    private func emaBBox(old: NormalizedRect, new: NormalizedRect, alpha: Double) -> NormalizedRect {
        func lerp(_ a: Double, _ b: Double) -> Double { a * (1 - alpha) + b * alpha }
        return NormalizedRect(
            origin: .init(x: lerp(old.origin.x, new.origin.x), y: lerp(old.origin.y, new.origin.y)),
            size: .init(width: lerp(old.size.width, new.size.width), height: lerp(old.size.height, new.size.height))
        )
    }

    private func iou(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
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
