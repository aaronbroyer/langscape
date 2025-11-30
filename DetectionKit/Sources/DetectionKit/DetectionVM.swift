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

#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

#if canImport(SegmentationKit)
import SegmentationKit
#endif

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
    @Published public private(set) var trackSnapshots: [DetectionTrackSnapshot] = []
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var lastError: DetectionError?
    @Published public private(set) var inputImageSize: CGSize?
#if canImport(CoreImage)
    @Published public private(set) var segmentationMasks: [UUID: CIImage] = [:]
#endif

    public let throttleInterval: TimeInterval

    private let logger: Logger
    private let processor: DetectionProcessor
    private var referee: VLMReferee?
    private var refiner: ClassificationRefiner?
    private let errorStore: ErrorStore
    private let auxiliaryRefereeEnabled = false
    private var lastSubmissionDate: Date = .distantPast
    private var fpsWindowStart: Date?
    private var processedFrames = 0
    private var droppedFrames = 0
    private let fpsWindow: TimeInterval
    private var auxiliaryLoadTask: Task<Void, Never>?
    private var trackState: [UUID: DetectionTrackSnapshot] = [:]
    private let trackRetentionDuration: TimeInterval = 2.5
#if canImport(SegmentationKit) && canImport(CoreVideo)
    private let segmentationServiceBox: AnyObject?
    private var pendingSegmentationDetections: Set<UUID> = []
    private var userRequestedSegmentationIDs: Set<UUID> = []
    private let segmentationConfidenceGate: Double = 0.85
    private let segmentationAreaGate: Double = 0.35
    private var automaticSegmentationEnabled = false
    private var segmentationFailureCount = 0
    private var segmentationSuspendUntil: Date?
    private var segmentationDisabled = false
    private let segmentationFailureLimit = 3
    private let segmentationFailureBackoff: TimeInterval = 10
    private var segmentationPrepared = false
    private var segmentationPrepareTask: Task<Void, Never>?
    private var maskMetadata: [UUID: SegmentationMaskMetadata] = [:]
    private let maskRefreshIoUThreshold: Double = 0.75
    private let maskRefreshInterval: TimeInterval = 1.5
#endif
    private let maxInFlightRequests = 3
    private var inFlightRequests = 0

    private init(
        service: any DetectionService,
        throttleInterval: TimeInterval,
        fpsWindow: TimeInterval,
        logger: Logger,
        errorStore: ErrorStore,
        geminiAPIKey: String?,
        segmentationServiceBox: AnyObject?
    ) {
        self.throttleInterval = throttleInterval
        self.logger = logger
        self.processor = DetectionProcessor(service: service)
        self.referee = nil
        self.refiner = nil
        self.fpsWindow = fpsWindow
        self.errorStore = errorStore
#if canImport(SegmentationKit) && canImport(CoreVideo)
        self.segmentationServiceBox = segmentationServiceBox
#else
        _ = segmentationServiceBox
#endif
        startAuxiliaryModelLoad(geminiAPIKey: geminiAPIKey)
#if canImport(SegmentationKit) && canImport(CoreVideo)
        if let serviceObject = segmentationServiceBox {
            startSegmentationPreparation(serviceObject: serviceObject)
        }
#endif
    }

#if canImport(SegmentationKit) && canImport(CoreVideo)
    public convenience init(
        service: any DetectionService,
        throttleInterval: TimeInterval = 0.06,
        fpsWindow: TimeInterval = 1,
        logger: Logger = .shared,
        errorStore: ErrorStore = .shared,
        geminiAPIKey: String? = nil,
        segmentationService: AnyObject? = nil
    ) {
        let resolvedService: AnyObject?
        if #available(iOS 17.0, macOS 15.0, tvOS 17.0, watchOS 10.0, *) {
            if let override = segmentationService as? SegmentationService {
                resolvedService = override
            } else {
                resolvedService = SegmentationService.shared
            }
        } else {
            resolvedService = nil
        }
        self.init(
            service: service,
            throttleInterval: throttleInterval,
            fpsWindow: fpsWindow,
            logger: logger,
            errorStore: errorStore,
            geminiAPIKey: geminiAPIKey,
            segmentationServiceBox: resolvedService
        )
    }
#else
    public convenience init(
        service: any DetectionService,
        throttleInterval: TimeInterval = 0.06,
        fpsWindow: TimeInterval = 1,
        logger: Logger = .shared,
        errorStore: ErrorStore = .shared,
        geminiAPIKey: String? = nil
    ) {
        self.init(
            service: service,
            throttleInterval: throttleInterval,
            fpsWindow: fpsWindow,
            logger: logger,
            errorStore: errorStore,
            geminiAPIKey: geminiAPIKey,
            segmentationServiceBox: nil
        )
    }
#endif

    public func setInputSize(_ size: CGSize) {
        self.inputImageSize = size
    }

    public func enqueue(_ request: DetectionRequest) {
        let logger = self.logger
        let now = Date()
        guard now.timeIntervalSince(lastSubmissionDate) >= throttleInterval else {
            droppedFrames += 1
            let dropped = droppedFrames
            Task { await logger.log("Dropping frame due to throttle (total dropped: \(dropped)).", level: .debug, category: "DetectionKit.DetectionVM") }
            return
        }

        guard inFlightRequests < maxInFlightRequests else {
            droppedFrames += 1
            let dropped = droppedFrames
            let backlog = inFlightRequests
            Task { await logger.log("Dropping frame because \(backlog) detection tasks are still running (total dropped: \(dropped)).", level: .debug, category: "DetectionKit.DetectionVM") }
            return
        }

        lastSubmissionDate = now
        inFlightRequests += 1
        let processor = self.processor
        let errorStore = self.errorStore

        Task(priority: .userInitiated) { [weak self] in
            guard let viewModel = self else { return }
            do {
                var detections = try await processor.process(request)
                #if canImport(CoreVideo)
                // First, optionally verify mid-confidence boxes using the VLM referee
                if let referee = viewModel.referee {
                    let pb: CVPixelBuffer = request.pixelBuffer
                    detections = referee.filter(
                        detections,
                        pixelBuffer: pb,
                        orientationRaw: request.imageOrientationRaw,
                        minConf: 0.30,
                        maxConf: 0.70
                    )
                }
                // Then, optionally refine labels via an image classifier
                if let refiner = viewModel.refiner {
                    let pb: CVPixelBuffer = request.pixelBuffer
                    detections = refiner.refine(detections, pixelBuffer: pb, orientationRaw: request.imageOrientationRaw)
                }
                #if canImport(SegmentationKit) && canImport(CoreVideo)
                await viewModel.evaluateSegmentationTriggers(
                    detections,
                    pixelBuffer: request.pixelBuffer,
                    timestamp: request.timestamp
                )
                #endif
                #endif
                let countForLog = detections.count
                let labelsForLog = detections.map { "\($0.label)(\(Int($0.confidence*100))%)" }.joined(separator: ", ")
                await MainActor.run {
                    viewModel.detections = detections
                    viewModel.lastError = nil
                    viewModel.updateTrackSnapshots(with: detections, timestamp: request.timestamp)
                    viewModel.registerFrame(timestamp: request.timestamp)
                }
                await logger.log("Processed frame \(request.id) with \(countForLog) detections: [\(labelsForLog)]", level: .debug, category: "DetectionKit.DetectionVM")
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
            await viewModel.finishInFlightRequest()
        }
    }

#if canImport(SegmentationKit) && canImport(CoreVideo)
    public func requestSegmentation(for detectionID: UUID) {
        userRequestedSegmentationIDs.insert(detectionID)
        let label = detections.first(where: { $0.id == detectionID })?.label ?? "unknown"
        Task { await logger.log("Segmentation manually requested for \(label) [\(detectionID)]", level: .debug, category: "DetectionKit.DetectionVM") }
    }

    public func setAutomaticSegmentationEnabled(_ enabled: Bool) {
        automaticSegmentationEnabled = enabled
    }

    public func consumeSegmentationMask(for detectionID: UUID) {
        // Masks persist per track; no manual consumption.
    }
#else
    public func requestSegmentation(for detectionID: UUID) {}
    public func setAutomaticSegmentationEnabled(_ enabled: Bool) {}
#if canImport(CoreImage)
    public func consumeSegmentationMask(for detectionID: UUID) {}
#endif
#endif

    private func startAuxiliaryModelLoad(geminiAPIKey: String?) {
        auxiliaryLoadTask?.cancel()
        let logger = self.logger
        auxiliaryLoadTask = Task(priority: .utility) { [weak self] in
            let loadReferee = self?.auxiliaryRefereeEnabled ?? false
            let result = await DetectionVM.prepareAuxiliaryModels(logger: logger, geminiAPIKey: geminiAPIKey, loadReferee: loadReferee)
            guard let self else { return }
            self.referee = result.referee
            self.refiner = result.refiner
        }
    }

#if canImport(SegmentationKit) && canImport(CoreVideo)
    private func startSegmentationPreparation(serviceObject: AnyObject) {
        guard #available(iOS 17.0, macOS 15.0, tvOS 17.0, watchOS 10.0, *),
              let service = serviceObject as? SegmentationService else { return }
        segmentationPrepareTask?.cancel()
        segmentationPrepared = false
        segmentationPrepareTask = Task { [weak self] in
            do {
                try await service.prepare()
                await MainActor.run {
                    guard let self else { return }
                    self.segmentationPrepared = true
                }
                await self?.logger.log("SegmentationService prepared", level: .info, category: "DetectionKit.DetectionVM")
            } catch {
                await self?.logger.log("SegmentationService prepare failed: \(error.localizedDescription)", level: .error, category: "DetectionKit.DetectionVM")
            }
            await MainActor.run { [weak self] in
                self?.segmentationPrepareTask = nil
            }
        }
    }
#endif

    nonisolated private static func prepareAuxiliaryModels(logger: Logger, geminiAPIKey: String?, loadReferee: Bool) async -> (referee: VLMReferee?, refiner: ClassificationRefiner?) {
        var loadedReferee: VLMReferee?
        var loadedRefiner: ClassificationRefiner?

        if loadReferee {
            do {
                loadedReferee = try VLMReferee(
                    cropSize: 256,
                    acceptGate: 0.85,
                    minKeepGate: 0.70,
                    maxProposals: 48,
                    geminiAPIKey: geminiAPIKey
                )
                await logger.log("DetectionVM: Auxiliary VLM referee loaded for client-side verification", level: .info, category: "DetectionKit.DetectionVM")
            } catch {
                await logger.log("DetectionVM: Skipping auxiliary referee (\(error.localizedDescription))", level: .warning, category: "DetectionKit.DetectionVM")
            }
        } else {
            await logger.log("DetectionVM: Auxiliary VLM referee disabled via feature flag", level: .info, category: "DetectionKit.DetectionVM")
        }

        do {
            loadedRefiner = try ClassificationRefiner()
            await logger.log("DetectionVM: Loaded classification refiner", level: .info, category: "DetectionKit.DetectionVM")
        } catch {
            await logger.log("DetectionVM: Classification refiner unavailable (\(error.localizedDescription))", level: .debug, category: "DetectionKit.DetectionVM")
        }

        return (loadedReferee, loadedRefiner)
    }

    public func registerFatalError(_ message: String, metadata: [String: String] = [:]) {
        lastError = .unknown(message)
        let combined = metadata.merging(["category": "DetectionKit.Fatal"]) { current, _ in current }
        Task { await logger.log(message, level: .error, category: "DetectionKit.Fatal") }
        Task { await errorStore.add(LoggedError(message: message, metadata: combined)) }
    }

#if canImport(SegmentationKit) && canImport(CoreVideo)
    @MainActor
    private func evaluateSegmentationTriggers(_ detections: [Detection], pixelBuffer: CVPixelBuffer, timestamp: Date) {
        guard #available(iOS 17.0, macOS 15.0, tvOS 17.0, watchOS 10.0, *),
              let service = segmentationServiceBox as? SegmentationService else { return }
        if !segmentationPrepared {
            if segmentationPrepareTask == nil {
                startSegmentationPreparation(serviceObject: service)
            }
            return
        }
        if segmentationDisabled { return }
        if let suspendUntil = segmentationSuspendUntil, Date() < suspendUntil { return }

        let availableIDs = Set(detections.map(\.id))
        if !userRequestedSegmentationIDs.isEmpty {
            let staleRequests = userRequestedSegmentationIDs.subtracting(availableIDs)
            if !staleRequests.isEmpty {
                userRequestedSegmentationIDs.subtract(staleRequests)
                Task { await logger.log("Segmentation: cleared \(staleRequests.count) stale requests", level: .debug, category: "DetectionKit.DetectionVM") }
            }
        }
        maskMetadata = maskMetadata.filter { availableIDs.contains($0.key) }

        let manualDetections = detections.filter { userRequestedSegmentationIDs.contains($0.id) }
        if let manualTarget = nextSegmentationCandidate(from: manualDetections, timestamp: timestamp, allowLargeTargets: true) {
            userRequestedSegmentationIDs.remove(manualTarget.id)
            scheduleSegmentation(for: manualTarget, reason: "manual", pixelBuffer: pixelBuffer, timestamp: timestamp, service: service)
            return
        }

        guard automaticSegmentationEnabled else { return }
        let autoEligible = detections.filter {
            $0.confidence >= segmentationConfidenceGate &&
            boundingBoxArea($0.boundingBox) <= segmentationAreaGate
        }
        if let autoTarget = nextSegmentationCandidate(from: autoEligible, timestamp: timestamp, allowLargeTargets: false) {
            scheduleSegmentation(for: autoTarget, reason: "automatic", pixelBuffer: pixelBuffer, timestamp: timestamp, service: service)
        }
    }

    private func nextSegmentationCandidate(
        from detections: [Detection],
        timestamp: Date,
        allowLargeTargets: Bool
    ) -> Detection? {
        for detection in detections {
            guard !pendingSegmentationDetections.contains(detection.id) else { continue }
            if !allowLargeTargets {
                guard detection.confidence >= segmentationConfidenceGate else { continue }
                guard boundingBoxArea(detection.boundingBox) <= segmentationAreaGate else { continue }
            }
            guard shouldRequestMask(for: detection, timestamp: timestamp) else { continue }
            return detection
        }
        return nil
    }

    private func shouldRequestMask(for detection: Detection, timestamp: Date) -> Bool {
        let id = detection.id
        if pendingSegmentationDetections.contains(id) { return false }
#if canImport(CoreImage)
        let hasMask = segmentationMasks[id] != nil
#else
        let hasMask = false
#endif
        guard let metadata = maskMetadata[id] else {
            return true
        }
        if !hasMask {
            return true
        }
        let moved = trackIoU(metadata.lastBoundingBox, detection.boundingBox) < maskRefreshIoUThreshold
        let stale = timestamp.timeIntervalSince(metadata.lastRequest) >= maskRefreshInterval
        return moved || stale
    }

    private func scheduleSegmentation(
        for detection: Detection,
        reason: String,
        pixelBuffer: CVPixelBuffer,
        timestamp: Date,
        service: SegmentationService
    ) {
        let prompt = promptRect(for: detection.boundingBox, pixelBuffer: pixelBuffer)
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let request = SegmentationRequest(
            pixelBuffer: pixelBuffer,
            prompt: prompt,
            imageSize: CGSize(width: width, height: height),
            timestamp: timestamp.timeIntervalSince1970
        )
        let detectionID = detection.id
        maskMetadata[detectionID] = SegmentationMaskMetadata(lastBoundingBox: detection.boundingBox, lastRequest: timestamp)
        pendingSegmentationDetections.insert(detectionID)

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                await self.logger.log("Segmentation starting for \(detection.label) (\(reason)) [\(detectionID)]", level: .debug, category: "DetectionKit.DetectionVM")
                let mask = try await service.segment(request)
                await MainActor.run {
#if canImport(CoreImage)
                    self.segmentationMasks[detectionID] = mask
#endif
                    self.pendingSegmentationDetections.remove(detectionID)
                    self.segmentationFailureCount = 0
                    self.segmentationSuspendUntil = nil
                    self.maskMetadata[detectionID] = SegmentationMaskMetadata(lastBoundingBox: detection.boundingBox, lastRequest: timestamp)
                }
                await self.logger.log("Segmentation mask ready for \(detection.label)", level: .info, category: "DetectionKit.DetectionVM")
            } catch {
                _ = await MainActor.run {
                    self.pendingSegmentationDetections.remove(detectionID)
                }
                await self.handleSegmentationFailure(error, label: detection.label)
            }
        }
    }
#endif

#if canImport(CoreVideo)
    @MainActor
    private func handleSegmentationFailure(_ error: Error, label: String) async {
        segmentationFailureCount += 1
        let message = "Segmentation failed for \(label): \(error.localizedDescription)"
        if segmentationFailureCount >= segmentationFailureLimit {
            segmentationDisabled = true
            #if canImport(CoreImage)
            segmentationMasks.removeAll()
            #endif
            await logger.log("\(message). Disabling segmentation for the remainder of the session.", level: .error, category: "DetectionKit.DetectionVM")
            return
        }
        segmentationSuspendUntil = Date().addingTimeInterval(segmentationFailureBackoff)
        await logger.log("\(message). Pausing segmentation for \(Int(segmentationFailureBackoff))s.", level: .warning, category: "DetectionKit.DetectionVM")
    }

    private func promptRect(for boundingBox: NormalizedRect, pixelBuffer: CVPixelBuffer) -> CGRect {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let x = CGFloat(boundingBox.origin.x) * width
        let y = CGFloat(boundingBox.origin.y) * height
        let w = CGFloat(boundingBox.size.width) * width
        let h = CGFloat(boundingBox.size.height) * height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func boundingBoxArea(_ rect: NormalizedRect) -> Double {
        let clampedWidth = max(0, min(1, rect.size.width))
        let clampedHeight = max(0, min(1, rect.size.height))
        return clampedWidth * clampedHeight
    }

    private func trackIoU(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
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
#endif

    private func finishInFlightRequest() {
        inFlightRequests = max(0, inFlightRequests - 1)
    }

    @MainActor
    private func updateTrackSnapshots(with detections: [Detection], timestamp: Date) {
        for detection in detections {
            trackState[detection.id] = DetectionTrackSnapshot(detection: detection, updatedAt: timestamp)
        }

        let expirationThreshold = timestamp.addingTimeInterval(-trackRetentionDuration)
        trackState = trackState.filter { $0.value.updatedAt >= expirationThreshold }

        let activeIDs = Set(trackState.keys)
        maskMetadata = maskMetadata.filter { activeIDs.contains($0.key) }
#if canImport(CoreImage)
        segmentationMasks = segmentationMasks.filter { activeIDs.contains($0.key) }
#endif

        trackSnapshots = trackState.values.sorted(by: { $0.updatedAt > $1.updatedAt })
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

#if canImport(SegmentationKit) && canImport(CoreVideo)
private struct SegmentationMaskMetadata {
    var lastBoundingBox: NormalizedRect
    var lastRequest: Date
}
#endif

// MARK: - Spatial Index for efficient track association

/// Spatial index using grid-based hashing for O(1) average-case lookup
/// Partitions the normalized [0,1]×[0,1] frame into a grid
private struct SpatialIndex {
    private var grid: [[UUID]]
    private let gridSize: Int

    init(gridSize: Int = 10) {
        self.gridSize = gridSize
        self.grid = Array(repeating: [], count: gridSize * gridSize)
    }

    /// Clear all entries
    mutating func clear() {
        grid = Array(repeating: [], count: gridSize * gridSize)
    }

    /// Insert a track into the spatial index
    mutating func insert(id: UUID, bbox: NormalizedRect) {
        let cells = getCells(for: bbox)
        for cell in cells {
            grid[cell].append(id)
        }
    }

    /// Query for track IDs that could potentially overlap with the given bbox
    func query(bbox: NormalizedRect) -> Set<UUID> {
        let cells = getCells(for: bbox)
        var results = Set<UUID>()
        for cell in cells {
            results.formUnion(grid[cell])
        }
        return results
    }

    /// Get grid cells that overlap with the given bounding box
    private func getCells(for bbox: NormalizedRect) -> [Int] {
        // Calculate grid cell range for this bbox
        let minX = Int(floor(bbox.origin.x * Double(gridSize)))
        let maxX = Int(floor((bbox.origin.x + bbox.size.width) * Double(gridSize)))
        let minY = Int(floor(bbox.origin.y * Double(gridSize)))
        let maxY = Int(floor((bbox.origin.y + bbox.size.height) * Double(gridSize)))

        // Clamp to grid bounds
        let x0 = max(0, min(gridSize - 1, minX))
        let x1 = max(0, min(gridSize - 1, maxX))
        let y0 = max(0, min(gridSize - 1, minY))
        let y1 = max(0, min(gridSize - 1, maxY))

        var cells: [Int] = []
        for y in y0...y1 {
            for x in x0...x1 {
                cells.append(y * gridSize + x)
            }
        }
        return cells
    }
}

private actor DetectionProcessor {
    private let service: any DetectionService
    private var prepared = false
    private var prepareTask: Task<Void, Error>?
    // Temporal smoothing state
    private var tracks: [UUID: Track] = [:]
    private var spatialIndex: SpatialIndex = SpatialIndex(gridSize: 10)

    // Tracking parameters (AGGRESSIVE: emit almost everything immediately)
    private let iouThreshold: Double = 0.30  // Very loose for crowded scenes
    private let maxTrackAge: TimeInterval = 1.0  // Keep tracks longer
    private let smoothingAlpha: Double = 0.1  // Minimal smoothing - show detections fast
    private let maxActiveTracks: Int = 10000  // Very high cap

    // Confidence-based hit requirements (AGGRESSIVE: emit immediately)
    private let highConfidenceHits: Int = 1  // >0.40: emit immediately
    private let midConfidenceHits: Int = 1   // 0.20-0.40: emit immediately
    private let lowConfidenceHits: Int = 1   // All detections: emit immediately (no filtering)

    // Label voting window (Phase 3)
    private let labelVotingWindow: Int = 5

    init(service: any DetectionService) {
        self.service = service
    }

    func process(_ request: DetectionRequest) async throws -> [Detection] {
        // Ensure preparation happens exactly once, even with concurrent calls
        if let task = prepareTask {
            // Wait for existing prepare task to complete
            try await task.value
        } else if !prepared {
            // Create and store the prepare task so concurrent calls can wait for it
            let task = Task {
                try await service.prepare()
            }
            prepareTask = task
            try await task.value
            prepared = true
            prepareTask = nil  // Clear task after completion
        }
        let raw = try await service.detect(on: request)
        print("DetectionProcessor: Got \(raw.count) raw detections from service")
        let stabilized = stabilize(detections: raw, timestamp: request.timestamp)
        print("DetectionProcessor: After stabilize: \(stabilized.count) detections")
        return stabilized
    }

    // MARK: - Stabilization
    private struct Track {
        let id: UUID
        var label: String
        var labelHistory: [(label: String, confidence: Double)]  // For weighted voting
        var bbox: NormalizedRect
        var confidence: Double
        var hits: Int
        var lastTimestamp: Date
    }

    private func stabilize(detections: [Detection], timestamp: Date) -> [Detection] {
        print("DetectionProcessor.stabilize: Input \(detections.count) detections, \(tracks.count) existing tracks")

        // Step 1: Rebuild spatial index with current tracks
        spatialIndex.clear()
        for (id, track) in tracks {
            spatialIndex.insert(id: id, bbox: track.bbox)
        }

        // Step 2: Associate detections to existing tracks using spatial indexing (O(n log n))
        var unmatchedTrackIDs = Set(tracks.keys)

        for det in detections {
            // Query spatial index for nearby tracks (much faster than checking all tracks)
            let nearbyIDs = spatialIndex.query(bbox: det.boundingBox)

            // Find best matching track among nearby candidates
            var bestID: UUID?
            var bestIoU: Double = 0
            for id in nearbyIDs {
                guard let tr = tracks[id] else { continue }
                let iouVal = iou(tr.bbox, det.boundingBox)
                if iouVal > bestIoU { bestIoU = iouVal; bestID = id }
            }

            if let id = bestID, bestIoU >= iouThreshold, var tr = tracks[id] {
                // EMA update for bbox and confidence
                tr.bbox = emaBBox(old: tr.bbox, new: det.boundingBox, alpha: smoothingAlpha)
                tr.confidence = tr.confidence * (1 - smoothingAlpha) + det.confidence * smoothingAlpha
                tr.hits += 1
                tr.lastTimestamp = timestamp

                // Enhanced label voting with history (Phase 3)
                var history = tr.labelHistory
                history.append((det.label.lowercased(), det.confidence))
                // Keep only last N frames for voting
                if history.count > labelVotingWindow {
                    history.removeFirst()
                }
                tr.labelHistory = history

                // Weighted voting: recent frames + higher confidence count more
                tr.label = weightedMajorityVote(history: history)
                tracks[id] = tr
                unmatchedTrackIDs.remove(id)
            } else {
                // New track
                let id = det.id
                tracks[id] = Track(
                    id: id,
                    label: det.label.lowercased(),
                    labelHistory: [(det.label.lowercased(), det.confidence)],
                    bbox: det.boundingBox,
                    confidence: det.confidence,
                    hits: 1,
                    lastTimestamp: timestamp
                )
            }
        }

        // Step 3: Age/prune unmatched tracks
        for id in unmatchedTrackIDs {
            if let tr = tracks[id], timestamp.timeIntervalSince(tr.lastTimestamp) > maxTrackAge {
                tracks.removeValue(forKey: id)
            }
        }

        // Step 4: Track capacity management (Phase 3)
        if tracks.count > maxActiveTracks {
            pruneLowestConfidenceTracks()
        }

        // Step 5: Emit stable tracks with confidence-based promotion (Phase 3)
        let stable = tracks.values.filter { tr in
            let requiredHits = getRequiredHits(confidence: tr.confidence)
            let meetsHits = tr.hits >= requiredHits
            let meetsAge = timestamp.timeIntervalSince(tr.lastTimestamp) <= maxTrackAge
            if !meetsHits || !meetsAge {
                print("DetectionProcessor.stabilize: Filtering track \(tr.label) - hits:\(tr.hits) >= \(requiredHits) = \(meetsHits), age:\(timestamp.timeIntervalSince(tr.lastTimestamp)) <= \(maxTrackAge) = \(meetsAge)")
            }
            return meetsHits && meetsAge
        }
        .sorted(by: { $0.confidence > $1.confidence })

        print("DetectionProcessor.stabilize: Emitting \(stable.count) stable tracks out of \(tracks.count) total tracks")

        return stable.map { tr in
            Detection(id: tr.id, label: tr.label, confidence: tr.confidence, boundingBox: tr.bbox)
        }
    }

    // MARK: - Helper Methods (Phase 3)

    /// Weighted majority vote for label stability
    /// Recent frames count more (exponential decay), higher confidence counts more
    private func weightedMajorityVote(history: [(label: String, confidence: Double)]) -> String {
        guard !history.isEmpty else { return "" }

        var scores: [String: Double] = [:]
        for (i, entry) in history.enumerated() {
            // Exponential decay: more recent = higher weight
            let recencyWeight = pow(0.8, Double(history.count - 1 - i))
            // Confidence weight
            let confidenceWeight = entry.confidence
            // Combined weight
            let weight = recencyWeight * confidenceWeight
            scores[entry.label, default: 0.0] += weight
        }

        return scores.max(by: { $0.value < $1.value })?.key ?? history.last!.label
    }

    /// Get required hits based on confidence (AGGRESSIVE: always 1 hit)
    private func getRequiredHits(confidence: Double) -> Int {
        // Emit everything immediately - no hit requirements
        return 1
    }

    /// Prune lowest-confidence tracks to stay within capacity limit
    private func pruneLowestConfidenceTracks() {
        let sorted = tracks.values.sorted(by: { $0.confidence > $1.confidence })
        let toPrune = sorted.dropFirst(maxActiveTracks)
        for track in toPrune {
            tracks.removeValue(forKey: track.id)
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
