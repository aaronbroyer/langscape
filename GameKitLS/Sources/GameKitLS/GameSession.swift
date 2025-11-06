import Foundation
import DetectionKit
import Utilities

public final class GameSession: @unchecked Sendable {
    private let detector: Detector
    private let logger: Logger
    private var history: [String]

    public init(detector: Detector = Detector(), logger: Logger = .shared) {
        self.detector = detector
        self.logger = logger
        self.history = []
    }

    public func submit(_ input: String) {
        history.append(input)
        Task {
            await logger.log("GameSession received input", level: .info, category: "GameKit")
            await detector.performDetection(on: input)
        }
    }

    public func lastEntries(limit: Int = 5) -> [String] {
        Array(history.suffix(limit))
    }
}
