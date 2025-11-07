import XCTest
@testable import VocabStore
import Utilities

final class VocabularyStoreTests: XCTestCase {
    func testLoadsBundledDataset() async {
        let store = VocabularyStore()
        let entries = await store.allEntries()

        XCTAssertGreaterThanOrEqual(entries.count, 70)

        let spanish = await store.translation(for: "book", preference: .englishToSpanish)
        XCTAssertEqual(spanish, "el libro")

        let english = await store.translation(for: "book", preference: .spanishToEnglish)
        XCTAssertEqual(english, "the book")
    }

    func testAddOverridesEntry() async {
        let store = VocabularyStore(entries: [])
        let initial = VocabularyStore.Entry(className: "tree", english: "the tree", spanish: "el árbol")
        await store.add(initial)

        let override = VocabularyStore.Entry(className: "tree", english: "the oak", spanish: "el roble")
        await store.add(override)

        let translated = await store.translation(for: "tree", preference: .englishToSpanish)
        XCTAssertEqual(translated, "el roble")
    }
}
