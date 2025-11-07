import XCTest
@testable import GameKitLS
import Utilities
import VocabStore
import LLMKit

final class LabelEngineTests: XCTestCase {
    func testUsesVocabularyEntriesForTranslations() async {
        let entry = VocabularyStore.Entry(className: "book", english: "the book", spanish: "el libro")
        let store = VocabularyStore(entries: [entry])
        let llm = MockLLMService(response: "ignored")
        let engine = LabelEngine(vocabularyStore: store, llmService: llm)

        let spanish = await engine.translation(for: "book", preference: .englishToSpanish)
        XCTAssertEqual(spanish, "el libro")

        let english = await engine.translation(for: "book", preference: .spanishToEnglish)
        XCTAssertEqual(english, "the book")

        let llmRequests = await llm.requestCount()
        XCTAssertEqual(llmRequests, 0)
    }

    func testFallsBackToLLMWhenVocabularyMissing() async {
        let store = VocabularyStore(entries: [])
        let llm = MockLLMService(response: "el árbol")
        let engine = LabelEngine(vocabularyStore: store, llmService: llm)

        let translated = await engine.translation(for: "tree", preference: .englishToSpanish)
        XCTAssertEqual(translated, "el árbol")

        // Repeated calls should hit the cache instead of the LLM again.
        let cached = await engine.translation(for: "tree", preference: .englishToSpanish)
        XCTAssertEqual(cached, "el árbol")

        let llmRequests = await llm.requestCount()
        XCTAssertEqual(llmRequests, 1)
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
