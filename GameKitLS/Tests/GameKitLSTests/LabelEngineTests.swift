import XCTest
@testable import GameKitLS
import Utilities
import LLMKit

final class LabelEngineTests: XCTestCase {
    func testUsesLLMForTranslations() async {
        let llm = MockLLMService(response: "el árbol")
        let engine = LabelEngine(llmService: llm)

        let translated = await engine.translation(for: "tree", preference: .englishToSpanish)
        XCTAssertEqual(translated, "el árbol")

        // Repeated calls should hit the cache instead of the LLM again.
        let cached = await engine.translation(for: "tree", preference: .englishToSpanish)
        XCTAssertEqual(cached, "el árbol")

        let llmRequests = await llm.requestCount()
        XCTAssertEqual(llmRequests, 1)
    }

    func testReturnsSourceTextWhenTargetIsEnglish() async {
        let llm = MockLLMService(response: "ignored")
        let engine = LabelEngine(llmService: llm)

        let english = await engine.translation(for: "book", preference: .spanishToEnglish)
        XCTAssertEqual(english, "book")

        let llmRequests = await llm.requestCount()
        XCTAssertEqual(llmRequests, 0)
    }
}

private actor MockLLMService: LLMServiceProtocol {
    private(set) var requests: [String] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        requests.append("\(source.rawValue)->\(target.rawValue):\(text)")
        return response
    }

    func requestCount() async -> Int {
        requests.count
    }
}
