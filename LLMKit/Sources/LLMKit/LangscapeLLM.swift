import Foundation
import Utilities

public struct LangscapeLLM: Sendable {
    private let logger: Logger

    public init(logger: Logger = .shared) {
        self.logger = logger
    }

    public func send(prompt: String) async -> String {
        await logger.log("LLM prompt sent", level: .info, category: "LLMKit")
        // Placeholder inference result
        return "Echo: \(prompt)"
    }
}
