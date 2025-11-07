import Foundation
import CoreGraphics
import Utilities

#if canImport(Combine)
import Combine
#else
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Published<Value> { self }
}
#endif

@MainActor
public final class DetectionVM: ObservableObject {
    @Published public private(set) var detections: [Detection] = []
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var lastError: DetectionError?
    @Published public private(set) var inputImageSize: CGSize?

    public let throttleInterval: TimeInterval

    private let logger: Logger
    private let processor: DetectionProcessor
    private var lastSubmissionDate: Date = .distantPast
    private var fpsWindowStart: Date?
    private var processedFrames = 0
    private var droppedFrames = 0
    private let fpsWindow: TimeInterval

    public init(
        service: any DetectionService,
        throttleInterval: TimeInterval = 0.15,
        fpsWindow: TimeInterval = 1,
        logger: Logger = .shared
    ) {
        self.throttleInterval = throttleInterval
        self.logger = logger
        self.processor = DetectionProcessor(service: service)
        self.fpsWindow = fpsWindow
    }

    public func setInputSize(_ size: CGSize) {
        self.inputImageSize = size
    }

    public func enqueue(_ request: DetectionRequest) {
        let now = Date()
        guard now.timeIntervalSince(lastSubmissionDate) >= throttleInterval else {
            droppedFrames += 1
            let dropped = droppedFrames
            let logger = self.logger
            Task { await logger.log("Dropping frame due to throttle (total dropped: \(dropped)).", level: .debug, category: "DetectionKit.DetectionVM") }
            return
        }

        lastSubmissionDate = now
        let logger = self.logger
        let processor = self.processor

        Task(priority: .userInitiated) { [weak self] in
            guard let viewModel = self else { return }
            do {
                let detections = try await processor.process(request)
                await MainActor.run {
                    viewModel.detections = detections
                    viewModel.lastError = nil
                    viewModel.registerFrame(timestamp: request.timestamp)
                }
                await logger.log(
                    "Processed frame \(request.id) with \(detections.count) detections.",
                    level: .debug,
                    category: "DetectionKit.DetectionVM"
                )
            } catch let error as DetectionError {
                await MainActor.run {
                    viewModel.lastError = error
                }
                await logger.log(error.errorDescription, level: .error, category: "DetectionKit.DetectionVM")
            } catch {
                await MainActor.run {
                    viewModel.lastError = .unknown(error.localizedDescription)
                }
                await logger.log("Unexpected detection error: \(error.localizedDescription)", level: .error, category: "DetectionKit.DetectionVM")
            }
        }
    }

    private func registerFrame(timestamp: Date) {
        if fpsWindowStart == nil {
            fpsWindowStart = timestamp
            processedFrames = 0
        }

        processedFrames += 1
        guard let start = fpsWindowStart else { return }
        let elapsed = timestamp.timeIntervalSince(start)
        guard elapsed >= fpsWindow else { return }

        fps = Double(processedFrames) / max(elapsed, 0.000_1)
        fpsWindowStart = timestamp
        processedFrames = 0

        let logger = self.logger
        let fpsValue = self.fps
        Task {
            let formatted = String(format: "%.2f", fpsValue)
            await logger.log("Detection FPS: \(formatted)", level: .info, category: "DetectionKit.DetectionVM")
        }
    }
}

private actor DetectionProcessor {
    private let service: any DetectionService
    private var prepared = false

    init(service: any DetectionService) {
        self.service = service
    }

    func process(_ request: DetectionRequest) async throws -> [Detection] {
        if !prepared {
            try await service.prepare()
            prepared = true
        }
        return try await service.detect(on: request)
    }
}
