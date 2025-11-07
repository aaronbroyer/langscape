import XCTest
@testable import GameKitLS
import DetectionKit

final class RoundGeneratorTests: XCTestCase {
    func testGeneratesRoundWithTranslations() {
        let detections = [
            Detection(label: "book", confidence: 0.92, boundingBox: normalizedRect(x: 0.1, y: 0.1)),
            Detection(label: "chair", confidence: 0.87, boundingBox: normalizedRect(x: 0.3, y: 0.2)),
            Detection(label: "clock", confidence: 0.76, boundingBox: normalizedRect(x: 0.5, y: 0.4)),
            Detection(label: "book", confidence: 0.81, boundingBox: normalizedRect(x: 0.2, y: 0.3))
        ]

        let translator = TestTranslator(mapping: [
            "book": "el libro",
            "chair": "la silla",
            "clock": "el reloj"
        ])

        let generator = RoundGenerator(minimumObjectCount: 3, maximumObjectCount: 5, translator: translator)
        let round = generator.makeRound(from: detections)

        XCTAssertNotNil(round)
        XCTAssertEqual(round?.objects.count, 3)
        XCTAssertEqual(round?.labels.count, 3)

        if let round {
            let translations = Set(round.labels.map { $0.text })
            XCTAssertEqual(translations, ["el libro", "la silla", "el reloj"])

            for label in round.labels {
                XCTAssertEqual(label.sourceLabel.lowercased(), round.object(with: label.objectID)?.sourceLabel.lowercased())
            }
        }
    }

    func testReturnsNilWhenInsufficientDetections() {
        let detections = [
            Detection(label: "book", confidence: 0.9, boundingBox: normalizedRect(x: 0.2, y: 0.2))
        ]

        let generator = RoundGenerator(minimumObjectCount: 3, maximumObjectCount: 5)
        let round = generator.makeRound(from: detections)

        XCTAssertNil(round)
    }

    private func normalizedRect(x: Double, y: Double) -> NormalizedRect {
        NormalizedRect(
            origin: .init(x: x, y: y),
            size: .init(width: 0.2, height: 0.2)
        )
    }
}

private struct TestTranslator: LabelTranslating {
    let mapping: [String: String]

    func translation(for sourceLabel: String) -> String {
        mapping[sourceLabel.lowercased()] ?? sourceLabel
    }
}
