import XCTest
@testable import GameKitLS
@testable import DetectionKit
@testable import Utilities

@MainActor
final class LabelScrambleVMTests: XCTestCase {
    func testPauseResumeAndExitResetState() async throws {
        let round = makeRound()
        let generator = StubRoundGenerator(nextRound: round, fallbackRound: nil)
        let viewModel = LabelScrambleVM(roundGenerator: generator, scanningTimeout: 0.01)

        viewModel.beginScanning()
        viewModel.ingestDetections([])
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.phase, .ready)

        viewModel.startRound()
        XCTAssertEqual(viewModel.phase, .playing)

        viewModel.pause()
        XCTAssertEqual(viewModel.phase, .paused)

        viewModel.resume()
        XCTAssertEqual(viewModel.phase, .playing)

        viewModel.exitToHome()
        XCTAssertEqual(viewModel.phase, .home)
        XCTAssertNil(viewModel.round)
        XCTAssertNil(viewModel.overlay)
    }

    func testNoObjectsOverlayPresentedAfterTimeout() async throws {
        let generator = StubRoundGenerator(nextRound: nil, fallbackRound: nil)
        let viewModel = LabelScrambleVM(roundGenerator: generator, scanningTimeout: 0.01)

        viewModel.beginScanning()
        viewModel.ingestDetections([])
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(viewModel.overlay, .noObjects)
        XCTAssertEqual(viewModel.phase, .home)
    }

    func testFatalOverlayPreventsResumingPlay() {
        let generator = StubRoundGenerator(nextRound: nil, fallbackRound: nil)
        let viewModel = LabelScrambleVM(roundGenerator: generator)

        viewModel.presentFatalError()
        XCTAssertEqual(viewModel.overlay, .fatal)
        XCTAssertEqual(viewModel.phase, .home)

        viewModel.beginScanning()
        XCTAssertEqual(viewModel.phase, .home)
        XCTAssertEqual(viewModel.overlay, .fatal)
    }

    private func makeRound() -> Round {
        let object = DetectedObject(
            sourceLabel: "cup",
            displayLabel: "Cup",
            boundingBox: .init(origin: .init(x: 0.1, y: 0.1), size: .init(width: 0.2, height: 0.2)),
            confidence: 0.9
        )
        let label = Label(text: "la taza", sourceLabel: "cup", objectID: object.id)
        return Round(objects: [object], labels: [label])
    }
}

private struct StubRoundGenerator: RoundGenerating {
    let nextRound: Round?
    let fallbackRound: Round?

    func makeRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round? {
        nextRound
    }

    func makeFallbackRound(from detections: [Detection], languagePreference: LanguagePreference) async -> Round? {
        fallbackRound
    }
}
