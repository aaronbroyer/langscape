import XCTest
@testable import GameKitLS
import DetectionKit

final class RoundTests: XCTestCase {
    func testUpdatingPrefersDetectionIDsOverLabels() {
        let baseRect = NormalizedRect(
            origin: .init(x: 0.1, y: 0.1),
            size: .init(width: 0.2, height: 0.2)
        )
        let initialDetection = Detection(id: UUID(), label: "tv", confidence: 0.9, boundingBox: baseRect)
        let object = DetectedObject(from: initialDetection)
        let label = Label(text: "el televisor", sourceLabel: "tv", objectID: object.id)
        let round = Round(objects: [object], labels: [label])

        let updatedRect = NormalizedRect(
            origin: .init(x: 0.2, y: 0.25),
            size: baseRect.size
        )
        let relabeledDetection = Detection(
            id: initialDetection.id,
            label: "television",
            confidence: 0.97,
            boundingBox: updatedRect
        )

        let refreshed = round.updating(with: [relabeledDetection])
        guard let refreshedObject = refreshed.objects.first else {
            return XCTFail("Expected object to persist after refresh")
        }

        XCTAssertEqual(refreshedObject.id, initialDetection.id)
        XCTAssertEqual(refreshedObject.boundingBox, updatedRect)
        XCTAssertEqual(refreshedObject.displayLabel, "Television")
        XCTAssertEqual(refreshed.labels.first?.objectID, refreshedObject.id)
    }
}
