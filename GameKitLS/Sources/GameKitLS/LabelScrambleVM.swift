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

    @Published public private(set) var phase: Phase
    @Published public private(set) var round: Round?
    @Published public private(set) var placedLabels: Set<Label.ID>
    @Published public private(set) var lastIncorrectLabelID: Label.ID?

    public var onRoundComplete: (() -> Void)?

    private let roundGenerator: RoundGenerator
    private let logger: Logger
    private var scanningBeganAt: Date?
    private let scanningTimeout: TimeInterval = 3.0

    public init(roundGenerator: RoundGenerator = RoundGenerator(), logger: Logger = .shared) {
        self.roundGenerator = roundGenerator
        self.logger = logger
        self.phase = .home
        self.round = nil
        self.placedLabels = []
        self.lastIncorrectLabelID = nil
    }

    public func beginScanning() {
        guard phase == .home else { return }
        placedLabels.removeAll()
        round = nil
        lastIncorrectLabelID = nil
        scanningBeganAt = Date()
        withAnimationIfAvailable { self.phase = .scanning }
        Task { await logger.log("Entered scanning phase", level: .info, category: "GameKitLS.LabelScrambleVM") }
    }

    public func ingestDetections(_ detections: [Detection]) {
        switch phase {
        case .scanning:
            if let generated = roundGenerator.makeRound(from: detections) {
                round = generated
                placedLabels = []
                withAnimationIfAvailable { self.phase = .ready }
                Task { await logger.log("Round ready with \(generated.objects.count) objects", level: .info, category: "GameKitLS.LabelScrambleVM") }
            } else if let start = scanningBeganAt, Date().timeIntervalSince(start) >= scanningTimeout {
                // Fallback after timeout: build a round from whatever unique detections we have (up to 3)
                let grouped = Dictionary(grouping: detections, by: { $0.label.lowercased() })
                let unique = grouped.values.compactMap { $0.max(by: { $0.confidence < $1.confidence }) }
                guard !unique.isEmpty else { return }
                let capped = Array(unique.prefix(3))
                let objects = capped.map(DetectedObject.init(from:))
                let translator = PlaceholderLabelTranslator()
                let labels = objects.map { Label(text: translator.translation(for: $0.sourceLabel), sourceLabel: $0.sourceLabel, objectID: $0.id) }
                let generated = Round(objects: objects, labels: labels)
                round = generated
                placedLabels = []
                withAnimationIfAvailable { self.phase = .ready }
                Task { await logger.log("Fallback round ready with \(generated.objects.count) objects", level: .info, category: "GameKitLS.LabelScrambleVM") }
            }
        case .ready:
            guard let currentRound = round else { return }
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
        withAnimationIfAvailable { self.phase = .home }
        round = nil
        placedLabels.removeAll()
        lastIncorrectLabelID = nil
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
        round = nil
        placedLabels.removeAll()
        lastIncorrectLabelID = nil
        withAnimationIfAvailable { self.phase = .home }
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
}

private func withAnimationIfAvailable(_ updates: @escaping () -> Void) {
    #if canImport(SwiftUI)
    SwiftUI.withAnimation { updates() }
    #else
    updates()
    #endif
}
