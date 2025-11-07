import XCTest
@testable import GameKitLS
import DetectionKit
import Utilities

final class RoundGeneratorTests: XCTestCase {
    func testGeneratesRoundWithTranslations() async {
        let detections = [
            Detection(label: "book", confidence: 0.92, boundingBox: normalizedRect(x: 0.1, y: 0.1)),
            Detection(label: "chair", confidence: 0.87, boundingBox: normalizedRect(x: 0.3, y: 0.2)),
            Detection(label: "clock", confidence: 0.76, boundingBox: normalizedRect(x: 0.5, y: 0.4)),
            Detection(label: "book", confidence: 0.81, boundingBox: normalizedRect(x: 0.2, y: 0.3))
        ]

        let provider = TestLabelProvider(mapping: [
            "book": "el libro",
            "chair": "la silla",
            "clock": "el reloj"
        ])

        let generator = RoundGenerator(minimumObjectCount: 3, maximumObjectCount: 5, labelProvider: provider)
        let round = await generator.makeRound(from: detections, languagePreference: .englishToSpanish)

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

    func testReturnsNilWhenInsufficientDetections() async {
        let detections = [
            Detection(label: "book", confidence: 0.9, boundingBox: normalizedRect(x: 0.2, y: 0.2))
        ]

        let generator = RoundGenerator(minimumObjectCount: 3, maximumObjectCount: 5)
        let round = await generator.makeRound(from: detections, languagePreference: .englishToSpanish)

        XCTAssertNil(round)
    }

    private func normalizedRect(x: Double, y: Double) -> NormalizedRect {
        NormalizedRect(
            origin: .init(x: x, y: y),
            size: .init(width: 0.2, height: 0.2)
        )
    }
}

private actor TestLabelProvider: LabelProviding {
    let mapping: [String: String]

    init(mapping: [String: String]) {
        self.mapping = mapping
    }

    func makeLabels(for objects: [DetectedObject], preference: LanguagePreference) async -> [Label] {
        objects.map { object in
            Label(
                text: mapping[object.sourceLabel.lowercased()] ?? object.sourceLabel,
                sourceLabel: object.sourceLabel,
                objectID: object.id
            )
        }
    }
}
