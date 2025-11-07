import XCTest
@testable import DetectionKit

final class DetectionVMTests: XCTestCase {
    func testThrottleDropsRapidFrames() async throws {
        let service = MockDetectionService(result: [Detection(label: "object", confidence: 0.9, boundingBox: .init(origin: .init(x: 0, y: 0), size: .init(width: 1, height: 1)))])
        let viewModel = await MainActor.run { DetectionVM(service: service, throttleInterval: 0.5, logger: .shared) }

        let buffer = FakePixelBuffer()
        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date(), pixelBuffer: buffer))
            viewModel.enqueue(DetectionRequest(timestamp: Date(), pixelBuffer: buffer))
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let processed = await service.processedCount()
        XCTAssertEqual(processed, 1, "Throttle should drop the second frame")
    }

    func testErrorPropagationPublishesLastError() async throws {
        let service = MockDetectionService(result: [], error: .inferenceFailed("forced"))
        let viewModel = await MainActor.run { DetectionVM(service: service, logger: .shared) }

        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date(), pixelBuffer: FakePixelBuffer()))
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let lastError = await MainActor.run { viewModel.lastError }
        XCTAssertEqual(lastError, .inferenceFailed("forced"))
    }
}

private actor MockDetectionService: DetectionService {
    private let result: [Detection]
    private let simulatedDelay: UInt64
    private let injectedError: DetectionError?
    private var processedCountStorage: Int = 0

    init(result: [Detection], delay: UInt64 = 50_000_000, error: DetectionError? = nil) {
        self.result = result
        self.simulatedDelay = delay
        self.injectedError = error
    }

    func prepare() async throws {}

    func detect(on request: DetectionRequest) async throws -> [Detection] {
        processedCountStorage += 1
        if let injectedError {
            throw injectedError
        }
        try await Task.sleep(nanoseconds: simulatedDelay)
        return result
    }

    func processedCount() -> Int {
        processedCountStorage
    }
}

private final class FakePixelBuffer: NSObject {}
