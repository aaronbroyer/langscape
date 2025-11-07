import Foundation
import Utilities

public protocol LLMClient: Sendable {
    func send(prompt: String) async -> String
}

public struct LangscapeLLM: LLMClient {
    private let logger: Logger

    public init(logger: Logger = .shared) {
        self.logger = logger
    }

    public func send(prompt: String) async -> String {
        await logger.log("LLM prompt sent", level: .info, category: "LLMKit")
        // Placeholder inference result while offline-only behaviour is validated.
        return "Echo: \(prompt)"
    }
}
