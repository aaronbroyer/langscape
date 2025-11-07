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

public protocol LabelTranslating: Sendable {
    func translation(for sourceLabel: String) -> String
}

public struct PlaceholderLabelTranslator: LabelTranslating {
    private static let defaultDictionary: [String: String] = [
        "person": "la persona",
        "bicycle": "la bicicleta",
        "car": "el coche",
        "motorcycle": "la motocicleta",
        "airplane": "el avión",
        "bus": "el autobús",
        "train": "el tren",
        "truck": "el camión",
        "boat": "el barco",
        "traffic light": "el semáforo",
        "fire hydrant": "la boca de incendio",
        "stop sign": "la señal de stop",
        "bench": "el banco",
        "bird": "el pájaro",
        "cat": "el gato",
        "dog": "el perro",
        "horse": "el caballo",
        "sheep": "la oveja",
        "cow": "la vaca",
        "elephant": "el elefante",
        "bear": "el oso",
        "zebra": "la cebra",
        "giraffe": "la jirafa",
        "backpack": "la mochila",
        "umbrella": "el paraguas",
        "handbag": "el bolso",
        "tie": "la corbata",
        "suitcase": "la maleta",
        "frisbee": "el frisbi",
        "skis": "los esquís",
        "snowboard": "la tabla de snowboard",
        "sports ball": "la pelota",
        "kite": "la cometa",
        "baseball bat": "el bate de béisbol",
        "baseball glove": "el guante de béisbol",
        "skateboard": "la patineta",
        "surfboard": "la tabla de surf",
        "tennis racket": "la raqueta de tenis",
        "bottle": "la botella",
        "wine glass": "la copa",
        "cup": "la taza",
        "fork": "el tenedor",
        "knife": "el cuchillo",
        "spoon": "la cuchara",
        "bowl": "el cuenco",
        "banana": "el plátano",
        "apple": "la manzana",
        "sandwich": "el sándwich",
        "orange": "la naranja",
        "broccoli": "el brócoli",
        "carrot": "la zanahoria",
        "hot dog": "el perrito caliente",
        "pizza": "la pizza",
        "donut": "la rosquilla",
        "cake": "el pastel",
        "chair": "la silla",
        "couch": "el sofá",
        "potted plant": "la planta en maceta",
        "bed": "la cama",
        "dining table": "la mesa",
        "toilet": "el inodoro",
        "tv": "el televisor",
        "laptop": "el portátil",
        "mouse": "el ratón",
        "remote": "el mando",
        "keyboard": "el teclado",
        "cell phone": "el móvil",
        "microwave": "el microondas",
        "oven": "el horno",
        "toaster": "la tostadora",
        "sink": "el fregadero",
        "refrigerator": "el refrigerador",
        "book": "el libro",
        "clock": "el reloj",
        "vase": "el jarrón",
        "scissors": "las tijeras",
        "teddy bear": "el osito",
        "hair drier": "el secador",
        "toothbrush": "el cepillo de dientes"
    ]

    public init() {}

    public func translation(for sourceLabel: String) -> String {
        let key = sourceLabel.lowercased()
        if let translation = Self.defaultDictionary[key] {
            return translation
        }
        return "el/la \(sourceLabel.lowercased())"
    }
}

public struct RoundGenerator: Sendable {
    public let minimumObjectCount: Int
    public let maximumObjectCount: Int

    private let translator: any LabelTranslating
    private let logger: Logger

    public init(
        minimumObjectCount: Int = 3,
        maximumObjectCount: Int = 6,
        translator: any LabelTranslating = PlaceholderLabelTranslator(),
        logger: Logger = .shared
    ) {
        self.minimumObjectCount = minimumObjectCount
        self.maximumObjectCount = max(minimumObjectCount, maximumObjectCount)
        self.translator = translator
        self.logger = logger
    }

    public func makeRound(from detections: [Detection]) -> Round? {
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
        let labels = objects.map { object in
            Label(text: translator.translation(for: object.sourceLabel), sourceLabel: object.sourceLabel, objectID: object.id)
        }

        Task { await logger.log("Generated round with \(objects.count) objects", level: .info, category: "GameKitLS.RoundGenerator") }
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
