import Foundation
import Utilities
import DetectionKit
#if canImport(SwiftUI)
import SwiftUI
#endif

@MainActor
public final class LabelScrambleVM: ObservableObject {
    public enum Phase: Equatable {
        case home
        case scanning
        case ready
        case playing
        case paused
        case completed
    }

    public enum MatchResult: Equatable {
        case matched(isRoundComplete: Bool)
        case mismatched
        case ignored
    }

    public enum Overlay: Equatable {
        case noObjects
        case fatal
    }

    @Published public private(set) var phase: Phase
    @Published public private(set) var round: Round?
    @Published public private(set) var placedLabels: Set<Label.ID>
    @Published public private(set) var lastIncorrectLabelID: Label.ID?
    @Published public private(set) var languagePreference: LanguagePreference
    @Published public private(set) var overlay: Overlay?

    public var onRoundComplete: (() -> Void)?

    private let roundGenerator: any RoundGenerating
    private let logger: Logger
    private var scanningBeganAt: Date?
    private let scanningTimeout: TimeInterval
    private var roundGenerationTask: Task<Void, Never>?
    // Stability gate before generating a round
    private var stableStart: Date?
    private let stabilityGate: TimeInterval = 0.8
    private let stabilityMinUnique: Int = 3

    public init(
        roundGenerator: any RoundGenerating = RoundGenerator(),
        languagePreference: LanguagePreference = .englishToSpanish,
        logger: Logger = .shared,
        scanningTimeout: TimeInterval = 3.0
    ) {
        self.roundGenerator = roundGenerator
        self.logger = logger
        self.phase = .home
        self.round = nil
        self.placedLabels = []
        self.lastIncorrectLabelID = nil
        self.languagePreference = languagePreference
        self.overlay = nil
        self.scanningTimeout = scanningTimeout
    }

    public func beginScanning() {
        guard phase == .home, overlay != .fatal else { return }
        roundGenerationTask?.cancel()
        placedLabels.removeAll()
        round = nil
        lastIncorrectLabelID = nil
        overlay = nil
        scanningBeganAt = Date()
        stableStart = nil
        withAnimationIfAvailable { self.phase = .scanning }
        Task { await logger.log("Entered scanning phase", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    public func ingestDetections(_ detections: [Detection]) {
        switch phase {
        case .scanning:
            if roundGenerationTask != nil { return }
            // Stability gate: require enough unique labels consistently for a short window
            let unique = Set(detections.map { $0.label.lowercased() }).count
            if unique >= stabilityMinUnique {
                if stableStart == nil { stableStart = Date() }
            } else {
                stableStart = nil
                return
            }
            if let s = stableStart, Date().timeIntervalSince(s) < stabilityGate { return }
            let preference = languagePreference
            let start = scanningBeganAt
            roundGenerationTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    Task { await MainActor.run { self.roundGenerationTask = nil } }
                }

                if let generated = await self.roundGenerator.makeRound(from: detections, languagePreference: preference) {
                    await self.prepareRound(generated, logMessage: "Round ready with \(generated.objects.count) objects")
                    return
                }

                if let start {
                    let elapsed = Date().timeIntervalSince(start)
                    let remaining = max(self.scanningTimeout - elapsed, 0)
                    if remaining > 0 {
                        let nanos = UInt64((remaining * 1_000_000_000).rounded())
                        if nanos > 0 {
                            try? await Task.sleep(nanoseconds: nanos)
                        }
                    }
                    if Task.isCancelled { return }

                    if let fallback = await self.roundGenerator.makeFallbackRound(from: detections, languagePreference: preference) {
                        await self.prepareRound(fallback, logMessage: "Fallback round ready with \(fallback.objects.count) objects")
                    } else {
                        await self.presentNoObjectsDetected()
                    }
                }
            }
        case .ready, .playing, .paused:
            guard let currentRound = round else { return }
            // Keep object positions fresh while playing so drops match the live view
            round = currentRound.updating(with: detections)
        default:
            break
        }
    }

    public func startRound() {
        guard phase == .ready, round != nil else { return }
        placedLabels = []
        lastIncorrectLabelID = nil
        withAnimationIfAvailable { self.phase = .playing }
        Task { await logger.log("Round started", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    public func pause() {
        guard phase == .playing else { return }
        withAnimationIfAvailable { self.phase = .paused }
        Task { await logger.log("Round paused", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    public func resume() {
        guard phase == .paused else { return }
        withAnimationIfAvailable { self.phase = .playing }
        Task { await logger.log("Round resumed", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    public func exitToHome() {
        roundGenerationTask?.cancel()
        withAnimationIfAvailable { self.phase = .home }
        round = nil
        placedLabels.removeAll()
        lastIncorrectLabelID = nil
        scanningBeganAt = nil
        if overlay != .fatal {
            overlay = nil
        }
        Task { await logger.log("Returned to home", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    @discardableResult
    public func attemptMatch(labelID: Label.ID, on objectID: DetectedObject.ID) -> MatchResult {
        guard phase == .playing, let round else { return .ignored }
        guard let expectedObjectID = round.target(for: labelID) else { return .ignored }

        if expectedObjectID == objectID {
            placedLabels.insert(labelID)
            Task { await logger.log("Correct match for label \(labelID)", level: .info, category: "GameKitLS.LabelScrambleVM") }

            if placedLabels.count == round.labels.count {
                withAnimationIfAvailable { self.phase = .completed }
                Task { await logger.log("Round completed", level: .info, category: "GameKitLS.LabelScrambleVM") }
                if let onRoundComplete {
                    onRoundComplete()
                }
                return .matched(isRoundComplete: true)
            }

            return .matched(isRoundComplete: false)
        } else {
            lastIncorrectLabelID = labelID
            Task { await logger.log("Incorrect match for label \(labelID)", level: .info, category: "GameKitLS.LabelScrambleVM") }
            scheduleIncorrectReset(for: labelID)
            return .mismatched
        }
    }

    public func acknowledgeCompletion() {
        guard phase == .completed else { return }
        roundGenerationTask?.cancel()
        round = nil
        placedLabels.removeAll()
        lastIncorrectLabelID = nil
        scanningBeganAt = nil
        withAnimationIfAvailable { self.phase = .home }
    }

    public func updateLanguagePreference(_ preference: LanguagePreference) {
        guard languagePreference != preference else { return }
        languagePreference = preference
        Task { await logger.log("Updated language preference to \(preference.rawValue)", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    public func retryAfterNoObjects() {
        guard overlay == .noObjects else { return }
        overlay = nil
        beginScanning()
    }

    public func presentFatalError() {
        guard overlay != .fatal else { return }
        roundGenerationTask?.cancel()
        round = nil
        placedLabels.removeAll()
        lastIncorrectLabelID = nil
        scanningBeganAt = nil
        overlay = .fatal
        withAnimationIfAvailable { self.phase = .home }
        Task { await logger.log("Presenting fatal error overlay", level: .error, category: "GameKitLS.LabelScrambleVM") }
    }

    private func scheduleIncorrectReset(for labelID: Label.ID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            await MainActor.run {
                if self.lastIncorrectLabelID == labelID {
                    self.lastIncorrectLabelID = nil
                }
            }
        }
    }
    private func prepareRound(_ generated: Round, logMessage: String) async {
        if Task.isCancelled { return }
        var didPrepare = false
        await MainActor.run {
            guard self.phase == .scanning else { return }
            self.round = generated
            self.placedLabels = []
            self.lastIncorrectLabelID = nil
            withAnimationIfAvailable { self.phase = .ready }
            didPrepare = true
        }
        guard didPrepare else { return }
        Task { await logger.log(logMessage, level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    private func presentNoObjectsDetected() async {
        await MainActor.run {
            guard self.phase == .scanning, self.overlay != .fatal else { return }
            self.round = nil
            self.placedLabels.removeAll()
            self.lastIncorrectLabelID = nil
            self.overlay = .noObjects
            withAnimationIfAvailable { self.phase = .home }
        }
        Task { await logger.log("No objects detected after timeout", level: .warning, category: "GameKitLS.LabelScrambleVM") }
    }
}

private func withAnimationIfAvailable(_ updates: @escaping () -> Void) {
    #if canImport(SwiftUI)
    SwiftUI.withAnimation { updates() }
    #else
    updates()
    #endif
}
