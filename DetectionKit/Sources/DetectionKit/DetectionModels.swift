import Foundation

public struct NormalizedRect: Sendable, Equatable {
    public struct Origin: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Size: Sendable, Equatable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public var origin: Origin
    public var size: Size

    public init(origin: Origin, size: Size) {
        self.origin = origin
        self.size = size
    }
}

public struct Detection: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let confidence: Double
    public let boundingBox: NormalizedRect

    public init(id: UUID = UUID(), label: String, confidence: Double, boundingBox: NormalizedRect) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct DetectionTrackSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let confidence: Double
    public let boundingBox: NormalizedRect
    public let updatedAt: Date

    public init(id: UUID, label: String, confidence: Double, boundingBox: NormalizedRect, updatedAt: Date) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.updatedAt = updatedAt
    }

    public init(detection: Detection, updatedAt: Date = Date()) {
        self.init(
            id: detection.id,
            label: detection.label,
            confidence: detection.confidence,
            boundingBox: detection.boundingBox,
            updatedAt: updatedAt
        )
    }
}
