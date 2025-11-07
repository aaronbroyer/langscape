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
            sourceLabel: detection.label,
            displayLabel: detection.label.capitalized,
            boundingBox: detection.boundingBox,
            confidence: detection.confidence
        )
    }

    public func updating(from detection: Detection) -> DetectedObject {
        DetectedObject(
            id: id,
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
        let grouped = Dictionary(grouping: detections, by: { $0.label.lowercased() })
        let updatedObjects: [DetectedObject] = objects.map { object in
            guard let candidates = grouped[object.sourceLabel.lowercased()], let match = candidates.max(by: { $0.confidence < $1.confidence }) else {
                return object
            }
            return object.updating(from: match)
        }
        return Round(id: id, objects: updatedObjects, labels: labels)
    }
}

public struct RoundGenerator: Sendable {
    public let minimumObjectCount: Int
    public let maximumObjectCount: Int

    private let labelProvider: any LabelProviding
    private let logger: Logger

    public init(
        minimumObjectCount: Int = 3,
        maximumObjectCount: Int = 6,
        labelProvider: any LabelProviding = LabelEngine(),
        logger: Logger = .shared
    ) {
        self.minimumObjectCount = minimumObjectCount
        self.maximumObjectCount = max(minimumObjectCount, maximumObjectCount)
        self.labelProvider = labelProvider
        self.logger = logger
    }

    public func makeRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round? {
        let deduplicated = deduplicate(detections: detections)
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
        let grouped = Dictionary(grouping: detections, by: { $0.label.lowercased() })
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
            seen.insert(key)
            results.append(detection)
        }
        return results
    }
}
