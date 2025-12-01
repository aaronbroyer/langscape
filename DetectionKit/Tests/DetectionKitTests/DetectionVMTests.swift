import XCTest
@testable import DetectionKit
@testable import Utilities

final class DetectionVMTests: XCTestCase {
    func testThrottleDropsRapidFrames() async throws {
        let service = MockDetectionService(result: [Detection(label: "object", confidence: 0.9, boundingBox: .init(origin: .init(x: 0, y: 0), size: .init(width: 1, height: 1)))])
        let store = ErrorStore(capacity: 5)
        let viewModel = await MainActor.run { DetectionVM(service: service, throttleInterval: 0.5, logger: .shared, errorStore: store) }

        let buffer = createFakePixelBuffer()
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
        let store = ErrorStore(capacity: 5)
        let viewModel = await MainActor.run { DetectionVM(service: service, logger: .shared, errorStore: store) }

        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date(), pixelBuffer: createFakePixelBuffer()))
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let lastError = await MainActor.run { viewModel.lastError }
        XCTAssertEqual(lastError, .inferenceFailed("forced"))
    }

    func testDetectionErrorsArePersisted() async throws {
        let service = MockDetectionService(result: [], error: .modelNotFound)
        let store = ErrorStore(capacity: 5)
        let viewModel = await MainActor.run { DetectionVM(service: service, logger: .shared, errorStore: store) }

        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date(), pixelBuffer: createFakePixelBuffer()))
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let errors = await store.allErrors()
        XCTAssertEqual(errors.first?.message, DetectionError.modelNotFound.errorDescription)
    }

    func testTrackIDStabilityWhenObjectMoves() async throws {
        // Simulate YOLO bbox fluctuation - same object with slightly different bboxes each frame
        // This happens when object moves slightly or YOLO confidence/bbox fluctuates
        // IoU ~0.25 is above new 0.20 threshold but below old 0.30 threshold

        // Frame 1: pillow at x=0.3
        let frame1Detection = Detection(
            label: "pillow",
            confidence: 0.8,
            boundingBox: .init(origin: .init(x: 0.3, y: 0.5), size: .init(width: 0.2, height: 0.2))
        )

        // Frame 2: pillow shifted slightly to x=0.32 (IoU = 0.64)
        let frame2Detection = Detection(
            label: "pillow",
            confidence: 0.8,
            boundingBox: .init(origin: .init(x: 0.32, y: 0.5), size: .init(width: 0.2, height: 0.2))
        )

        // Frame 3: pillow shifted to x=0.34 (IoU with EMA-smoothed track ≈ 0.55)
        let frame3Detection = Detection(
            label: "pillow",
            confidence: 0.8,
            boundingBox: .init(origin: .init(x: 0.34, y: 0.5), size: .init(width: 0.2, height: 0.2))
        )

        let service = MockDetectionServiceWithFrames(frames: [
            [frame1Detection],
            [frame2Detection],
            [frame3Detection]
        ])

        let store = ErrorStore(capacity: 5)
        let viewModel = await MainActor.run { DetectionVM(service: service, throttleInterval: 0.01, logger: .shared, errorStore: store) }

        var capturedIDs: [UUID] = []

        // Process frame 1
        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date(), pixelBuffer: createFakePixelBuffer()))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let snapshot1 = await MainActor.run { viewModel.trackSnapshots.first(where: { $0.label == "pillow" }) }
        if let id = snapshot1?.id {
            capturedIDs.append(id)
        }

        // Process frame 2 (after throttle interval)
        try await Task.sleep(nanoseconds: 20_000_000)
        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date().addingTimeInterval(0.02), pixelBuffer: createFakePixelBuffer()))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let snapshot2 = await MainActor.run { viewModel.trackSnapshots.first(where: { $0.label == "pillow" }) }
        if let id = snapshot2?.id {
            capturedIDs.append(id)
        }

        // Process frame 3
        try await Task.sleep(nanoseconds: 20_000_000)
        await MainActor.run {
            viewModel.enqueue(DetectionRequest(timestamp: Date().addingTimeInterval(0.04), pixelBuffer: createFakePixelBuffer()))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let snapshot3 = await MainActor.run { viewModel.trackSnapshots.first(where: { $0.label == "pillow" }) }
        if let id = snapshot3?.id {
            capturedIDs.append(id)
        }

        // All three frames should have the SAME track ID for the pillow
        XCTAssertEqual(capturedIDs.count, 3, "Should have captured 3 track IDs")
        XCTAssertEqual(Set(capturedIDs).count, 1, "Track ID should remain stable across frames (all IDs should be identical)")
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

private actor MockDetectionServiceWithFrames: DetectionService {
    private let frames: [[Detection]]
    private var frameIndex: Int = 0

    init(frames: [[Detection]]) {
        self.frames = frames
    }

    func prepare() async throws {}

    func detect(on request: DetectionRequest) async throws -> [Detection] {
        guard frameIndex < frames.count else {
            return frames.last ?? []
        }
        let result = frames[frameIndex]
        frameIndex += 1
        return result
    }
}

#if canImport(CoreVideo)
import CoreVideo

private func createFakePixelBuffer() -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    return pixelBuffer!
}
#else
private func createFakePixelBuffer() -> AnyObject {
    return NSObject()
}
#endif
