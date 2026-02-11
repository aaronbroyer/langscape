import Foundation
import DetectionKit
import Utilities

public struct DetectedObject: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceLabel: String
    public let displayLabel: String
    public let boundingBox: NormalizedRect
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        sourceLabel: String,
        displayLabel: String,
        boundingBox: NormalizedRect,
        confidence: Double
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.displayLabel = displayLabel
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    public init(from detection: Detection) {
        self.init(
            id: detection.id,
            sourceLabel: detection.label,
            displayLabel: detection.label.capitalized,
            boundingBox: detection.boundingBox,
            confidence: detection.confidence
        )
    }

    public func updating(from detection: Detection) -> DetectedObject {
        DetectedObject(
            id: detection.id,
            sourceLabel: sourceLabel,
            displayLabel: detection.label.capitalized,
            boundingBox: detection.boundingBox,
            confidence: detection.confidence
        )
    }
}

public struct Label: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let sourceLabel: String
    public let objectID: DetectedObject.ID

    public init(id: UUID = UUID(), text: String, sourceLabel: String, objectID: DetectedObject.ID) {
        self.id = id
        self.text = text
        self.sourceLabel = sourceLabel
        self.objectID = objectID
    }
}

public struct Round: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let objects: [DetectedObject]
    public let labels: [Label]

    private let matches: [Label.ID: DetectedObject.ID]

    public init(id: UUID = UUID(), objects: [DetectedObject], labels: [Label]) {
        self.id = id
        self.objects = objects
        self.labels = labels
        self.matches = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.objectID) })
    }

    public func target(for labelID: Label.ID) -> DetectedObject.ID? {
        matches[labelID]
    }

    public func object(with id: DetectedObject.ID) -> DetectedObject? {
        objects.first { $0.id == id }
    }

    public func label(with id: Label.ID) -> Label? {
        labels.first { $0.id == id }
    }

    public func updating(with detections: [Detection]) -> Round {
        let detectionLookup = Dictionary(uniqueKeysWithValues: detections.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: detections, by: { $0.label.lowercased() })
        var replacements: [DetectedObject.ID: DetectedObject.ID] = [:]
        let updatedObjects: [DetectedObject] = objects.map { object in
            if let directMatch = detectionLookup[object.id] {
                return object.updating(from: directMatch)
            }
            guard let candidates = grouped[object.sourceLabel.lowercased()],
                  let match = candidates.max(by: { $0.confidence < $1.confidence }) else {
                return object
            }
            let refreshed = object.updating(from: match)
            if refreshed.id != object.id {
                replacements[object.id] = refreshed.id
            }
            return refreshed
        }
        if replacements.isEmpty {
            return Round(id: id, objects: updatedObjects, labels: labels)
        }
        let updatedLabels: [Label] = labels.map { label in
            guard let newObjectID = replacements[label.objectID] else {
                return label
            }
            return Label(id: label.id, text: label.text, sourceLabel: label.sourceLabel, objectID: newObjectID)
        }
        return Round(id: id, objects: updatedObjects, labels: updatedLabels)
    }
}

public protocol RoundGenerating: Sendable {
    func makeRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round?
    func makeFallbackRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round?
}

public struct RoundGenerator: RoundGenerating {
    public let minimumObjectCount: Int
    public let maximumObjectCount: Int
    public let minConfidence: Double
    private let frameEdgeInset: Double = 0.02

    private let labelProvider: any LabelProviding
    private let logger: Logger

    public init(
        minimumObjectCount: Int = 3,
        maximumObjectCount: Int = 6,
        labelProvider: any LabelProviding = LabelEngine(),
        minConfidence: Double = 0.50,
        logger: Logger = .shared
    ) {
        self.minimumObjectCount = minimumObjectCount
        self.maximumObjectCount = max(minimumObjectCount, maximumObjectCount)
        self.labelProvider = labelProvider
        self.minConfidence = minConfidence
        self.logger = logger
    }

    public func makeRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round? {
        let playable = detections.filter(isFullyInsidePlayableFrame)
        let filteredCount = detections.count - playable.count
        if filteredCount > 0 {
            Task {
                await logger.log(
                    "Filtered \(filteredCount) edge-clipped detections from round candidates",
                    level: .debug,
                    category: "GameKitLS.RoundGenerator"
                )
            }
        }

        let confident = playable.filter { $0.confidence >= minConfidence }
        let deduplicated = deduplicate(detections: confident)
        guard deduplicated.count >= minimumObjectCount else {
            Task { await logger.log("Insufficient detections for round", level: .debug, category: "GameKitLS.RoundGenerator") }
            return nil
        }

        var shuffled = deduplicated
        shuffled.shuffle()
        let cappedCount = min(maximumObjectCount, shuffled.count)
        let selected = Array(shuffled.prefix(cappedCount))
        let objects = selected.map(DetectedObject.init(from:))
        let labels = await labelProvider.makeLabels(for: objects, preference: languagePreference)

        Task { await logger.log("Generated round with \(objects.count) objects", level: .info, category: "GameKitLS.RoundGenerator") }
        return Round(objects: objects, labels: labels)
    }

    public func makeFallbackRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round? {
        let playable = detections.filter(isFullyInsidePlayableFrame)
        let grouped = Dictionary(grouping: playable.filter { $0.confidence >= max(0.2, minConfidence * 0.8) }, by: { $0.label.lowercased() })
        let unique = grouped.values.compactMap { $0.max(by: { $0.confidence < $1.confidence }) }
        guard !unique.isEmpty else { return nil }

        let capped = Array(unique.prefix(max(3, minimumObjectCount)))
        let objects = capped.map(DetectedObject.init(from:))
        let labels = await labelProvider.makeLabels(for: objects, preference: languagePreference)

        Task { await logger.log("Generated fallback round", level: .info, category: "GameKitLS.RoundGenerator") }
        return Round(objects: objects, labels: labels)
    }

    private func deduplicate(detections: [Detection]) -> [Detection] {
        var seen: Set<String> = []
        var results: [Detection] = []
        for detection in detections {
            let key = detection.label.lowercased()
            guard !seen.contains(key) else { continue }
            // Filter out tiny or extreme aspect boxes which are hard to target
            let w = detection.boundingBox.size.width
            let h = detection.boundingBox.size.height
            let area = w * h
            let aspect = max(w, h) / max(0.0001, min(w, h))
            guard area >= 0.010 && aspect <= 4.0 else { continue }
            seen.insert(key)
            results.append(detection)
        }
        return results
    }

    private func isFullyInsidePlayableFrame(_ detection: Detection) -> Bool {
        let xMin = detection.boundingBox.origin.x
        let yMin = detection.boundingBox.origin.y
        let xMax = detection.boundingBox.origin.x + detection.boundingBox.size.width
        let yMax = detection.boundingBox.origin.y + detection.boundingBox.size.height

        return xMin >= frameEdgeInset &&
            yMin >= frameEdgeInset &&
            xMax <= (1 - frameEdgeInset) &&
            yMax <= (1 - frameEdgeInset)
    }
}
