import Foundation
import Utilities

public actor VocabularyStore {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let phrase: String
        public let translation: String

        public init(id: UUID = UUID(), phrase: String, translation: String) {
            self.id = id
            self.phrase = phrase
            self.translation = translation
        }
    }

    private var entries: [Entry]
    private let logger: Logger

    public init(entries: [Entry] = [], logger: Logger = .shared) {
        self.entries = entries
        self.logger = logger
    }

    public func add(_ entry: Entry) {
        entries.append(entry)
        Task { await logger.log("Stored vocabulary entry", level: .info, category: "VocabStore") }
    }

    public func all() -> [Entry] {
        entries
    }
}
