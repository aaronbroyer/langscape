#if canImport(SwiftUI)
import SwiftUI
import CoreImage
import DetectionKit
import GameKitLS
import Utilities

#if canImport(CoreVideo)
import CoreVideo
#endif

#if canImport(UIKit)
import UIKit
#endif

enum GameState: Equatable {
    case identifyingContext
    case confirmContext
    case hunting
    case scanning
    case playing
    case summary
}

@MainActor
final class DetectionVM: ObservableObject {
    enum Overlay: Equatable {
        case noObjects
        case fatal
    }

    @Published var state: GameState = .identifyingContext
    @Published var detectedContext: String?
    @Published var liveObjectCount: Int = 0
    @Published var snapshot: UIImage?
    @Published var snapshotImageSize: CGSize?
    @Published var modelInputSize: CGSize?
    @Published var round: Round?
    @Published var placedLabels: Set<GameKitLS.Label.ID> = []
    @Published var lastIncorrectLabelID: GameKitLS.Label.ID?
    @Published var overlay: Overlay?
    @Published var inputImageSize: CGSize?
    @Published var isPaused: Bool = false
    @Published var showIdentifiedObjectsHint: Bool = false

    private let logger: Logger
    private let settings: AppSettings
    private let objectDetector: CombinedDetector
    private let liveDetector: YOLOInterpreter
    private let sceneClassifier: VLMDetector
    private let roundGenerator: any RoundGenerating

    #if canImport(CoreVideo)
    private var currentPixelBuffer: CVPixelBuffer?
    private var currentOrientationRaw: UInt32?
    #endif

    private var classifierPrepared = false
    private var liveDetectorPrepared = false
    private var lastContextAttempt: Date = .distantPast
    private var lastLiveAttempt: Date = .distantPast
    private var liveInFlight = false
    private var contextInFlight = false

    private let contextThrottle: TimeInterval = 0.9
    private let liveThrottle: TimeInterval = 0.35

    init(
        settings: AppSettings,
        objectDetector: CombinedDetector,
        logger: Logger = .shared,
        sceneClassifier: VLMDetector = VLMDetector(),
        liveDetector: YOLOInterpreter = YOLOInterpreter(confidenceThreshold: 0.20, iouThreshold: 0.40),
        roundGenerator: any RoundGenerating = RoundGenerator()
    ) {
        self.settings = settings
        self.objectDetector = objectDetector
        self.logger = logger
        self.sceneClassifier = sceneClassifier
        self.liveDetector = liveDetector
        self.roundGenerator = roundGenerator
    }

    func start() {
        overlay = nil
        detectedContext = nil
        liveObjectCount = 0
        snapshot = nil
        snapshotImageSize = nil
        modelInputSize = nil
        round = nil
        placedLabels = []
        lastIncorrectLabelID = nil
        isPaused = false
        showIdentifiedObjectsHint = false
        state = .identifyingContext
    }

    func exitToHome() {
        start()
    }

    func onContextFound(_ context: String) {
        guard state == .identifyingContext else { return }
        detectedContext = context
        state = .confirmContext
    }

    func confirmContext() {
        guard state == .confirmContext, let context = detectedContext else { return }
        overlay = nil
        liveObjectCount = 0
        state = .hunting
        #if canImport(CoreVideo)
        kickstartLiveDetection()
        #endif

        Task { [objectDetector, liveDetector, logger] in
            _ = await objectDetector.loadContext(context)
            do {
                if !liveDetectorPrepared {
                    try await liveDetector.prepare()
                    liveDetectorPrepared = true
                }
                try await liveDetector.loadContext(context)
            } catch {
                await logger.log("Live detector context load failed: \(error.localizedDescription)", level: .warning, category: "LangscapeApp.DetectionVM")
            }
        }
    }

    func retryContext() {
        guard state == .confirmContext else { return }
        detectedContext = nil
        state = .identifyingContext
    }

    func pause() {
        guard state == .playing, !isPaused else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            isPaused = true
        }
    }

    func resume() {
        guard isPaused else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            isPaused = false
        }
    }

    func toggleIdentifiedObjectsHint() {
        guard state == .playing else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            showIdentifiedObjectsHint.toggle()
        }
    }

    @discardableResult
    func attemptMatch(labelID: GameKitLS.Label.ID, on objectID: UUID) -> LabelScrambleVM.MatchResult {
        guard state == .playing, !isPaused, let round else { return .ignored }
        guard let expectedObjectID = round.target(for: labelID) else { return .ignored }

        if expectedObjectID == objectID {
            placedLabels.insert(labelID)
            if placedLabels.count == round.labels.count {
                Task { [weak self] in
                    await self?.completeRound()
                }
                return .matched(isRoundComplete: true)
            }
            return .matched(isRoundComplete: false)
        } else {
            lastIncorrectLabelID = labelID
            scheduleIncorrectReset(for: labelID)
            return .mismatched
        }
    }

    private func scheduleIncorrectReset(for labelID: GameKitLS.Label.ID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            if self.lastIncorrectLabelID == labelID {
                self.lastIncorrectLabelID = nil
            }
        }
    }

    private func completeRound() async {
        guard state == .playing else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            state = .summary
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        await MainActor.run {
            snapshot = nil
            snapshotImageSize = nil
            modelInputSize = nil
            round = nil
            placedLabels = []
            lastIncorrectLabelID = nil
            isPaused = false
            showIdentifiedObjectsHint = false
            liveObjectCount = 0
            state = .hunting
        }
    }

    #if canImport(CoreVideo)
    func handleFrame(_ buffer: CVPixelBuffer, orientationRaw: UInt32?, orientedInputSize: CGSize) {
        currentPixelBuffer = buffer
        currentOrientationRaw = orientationRaw
        if inputImageSize != orientedInputSize {
            inputImageSize = orientedInputSize
        }

        switch state {
        case .identifyingContext:
            processContextFrame(buffer)
        case .hunting:
            processLiveFrame(buffer)
        default:
            break
        }
    }

    private func processContextFrame(_ buffer: CVPixelBuffer) {
        guard !contextInFlight else { return }
        let now = Date()
        guard now.timeIntervalSince(lastContextAttempt) >= contextThrottle else { return }
        lastContextAttempt = now
        contextInFlight = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.contextInFlight = false }
            do {
                if !classifierPrepared {
                    try await sceneClassifier.prepare()
                    classifierPrepared = true
                }
                let sensed = await sceneClassifier.classifyScene(pixelBuffer: buffer)
                let normalized = sensed.isEmpty ? "General" : sensed
                if normalized.caseInsensitiveCompare("general") == .orderedSame {
                    return
                }
                await MainActor.run {
                    self.onContextFound(normalized)
                }
            } catch {
                await logger.log("Context classification failed: \(error.localizedDescription)", level: .warning, category: "LangscapeApp.DetectionVM")
            }
        }
    }

    private func processLiveFrame(_ buffer: CVPixelBuffer) {
        guard !liveInFlight else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLiveAttempt) >= liveThrottle else { return }
        lastLiveAttempt = now
        liveInFlight = true

        let orientationRaw = currentOrientationRaw
        Task { [weak self] in
            guard let self else { return }
            defer { self.liveInFlight = false }
            do {
                if !liveDetectorPrepared {
                    try await liveDetector.prepare()
                    liveDetectorPrepared = true
                }
                let request = DetectionRequest(pixelBuffer: buffer, imageOrientationRaw: orientationRaw)
                let detections = try await liveDetector.detect(on: request)
                await MainActor.run {
                    self.liveObjectCount = detections.count
                }
            } catch {
                await logger.log("Live detection failed: \(error.localizedDescription)", level: .debug, category: "LangscapeApp.DetectionVM")
            }
        }
    }

    private func kickstartLiveDetection() {
        guard state == .hunting else { return }
        guard !liveInFlight else { return }
        guard let buffer = currentPixelBuffer else { return }
        lastLiveAttempt = .distantPast
        processLiveFrame(buffer)
    }

    func captureAndScan() {
        guard state == .hunting else { return }
        guard let currentBuffer = currentPixelBuffer else { return }
        overlay = nil
        isPaused = false
        showIdentifiedObjectsHint = false
        state = .scanning

        let orientationRaw = currentOrientationRaw
        Task { [weak self] in
            guard let self else { return }
            await self.freezeSnapshot(from: currentBuffer, orientationRaw: orientationRaw)
        }

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await objectDetector.prepare()
                let detectorInputSize = await objectDetector.modelInputSize()
                let request = DetectionRequest(pixelBuffer: currentBuffer, imageOrientationRaw: orientationRaw)
                let detections = try await objectDetector.detect(on: request)

                let preference = settings.selectedLanguage
                let generated = await roundGenerator.makeRound(from: detections, languagePreference: preference)
                let round: Round?
                if let generated {
                    round = generated
                } else {
                    round = await roundGenerator.makeFallbackRound(from: detections, languagePreference: preference)
                }

                guard let round else {
                    await MainActor.run {
                        self.overlay = .noObjects
                        self.state = .hunting
                    }
                    return
                }

                await MainActor.run {
                    self.modelInputSize = detectorInputSize
                    self.round = round
                    self.placedLabels = []
                    self.lastIncorrectLabelID = nil
                    self.showIdentifiedObjectsHint = false
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        self.state = .playing
                    }
                }
            } catch {
                await logger.log("Scan failed: \(error.localizedDescription)", level: .error, category: "LangscapeApp.DetectionVM")
                await MainActor.run {
                    self.overlay = .fatal
                    self.state = .hunting
                }
            }
        }
    }

    private func freezeSnapshot(from buffer: CVPixelBuffer, orientationRaw: UInt32?) async {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let oriented = orientationRaw.flatMap { ciImage.oriented(forExifOrientation: Int32($0)) } ?? ciImage
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(oriented, from: oriented.extent) else { return }
        await MainActor.run {
            self.snapshot = UIImage(cgImage: cg)
            self.snapshotImageSize = CGSize(width: cg.width, height: cg.height)
        }
    }

    #endif
}
#endif
