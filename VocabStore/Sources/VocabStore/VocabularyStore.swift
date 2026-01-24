import Foundation
import Utilities

public actor VocabularyStore {
    public struct Entry: Identifiable, Equatable, Codable, Sendable {
        public let id: UUID
        public let className: String
        public let english: String
        public let spanish: String
        public let french: String?

        public init(id: UUID = UUID(), className: String, english: String, spanish: String, french: String? = nil) {
            self.id = id
            self.className = className
            self.english = english
            self.spanish = spanish
            self.french = french
        }

        fileprivate var normalizedClassName: String {
            className.normalizedKey()
        }

        public func text(for language: Language) -> String? {
            switch language {
            case .english:
                return english
            case .spanish:
                return spanish
            case .french:
                return french
            }
        }

        public func translation(for preference: LanguagePreference) -> String? {
            text(for: preference.targetLanguage)
        }
    }

    private struct RawDataset: Decodable {
        struct Item: Decodable {
            let className: String
            let english: String
            let spanish: String
            let french: String?
        }

        let items: [Item]
    }

    private enum Constants {
        static let resourceName = "vocab-es-en"
        static let resourceExtension = "json"
    }

    private var entriesByClass: [String: Entry]
    private let logger: Logger

    public init(entries: [Entry]? = nil, bundle: Bundle? = nil, logger: Logger = .shared) {
        self.logger = logger
        if let entries {
            self.entriesByClass = Dictionary(uniqueKeysWithValues: entries.map { ($0.normalizedClassName, $0) })
        } else {
            let resourceBundle = bundle ?? .module
            self.entriesByClass = VocabularyStore.loadEntries(from: resourceBundle, logger: logger)
        }
    }

    public func add(_ entry: Entry) {
        entriesByClass[entry.normalizedClassName] = entry
        Task { await logger.log("Stored vocabulary entry for \(entry.className)", level: .info, category: "VocabStore") }
    }

    public func allEntries() -> [Entry] {
        entriesByClass.values.sorted(by: { $0.className < $1.className })
    }

    public func entry(for className: String) -> Entry? {
        let key = className.normalizedKey()
        if let direct = entriesByClass[key] { return direct }
        if let alias = VocabularyStore.aliases[key], let mapped = entriesByClass[alias] {
            return mapped
        }
        return nil
    }

    public func translation(for className: String, preference: LanguagePreference) -> String? {
        entry(for: className)?.translation(for: preference)
    }

    public func loadBundledEntries(from bundle: Bundle? = nil) {
        let resourceBundle = bundle ?? .module
        entriesByClass = VocabularyStore.loadEntries(from: resourceBundle, logger: logger)
    }

    private static func loadEntries(from bundle: Bundle, logger: Logger) -> [String: Entry] {
        guard let url = bundle.url(forResource: Constants.resourceName, withExtension: Constants.resourceExtension) else {
            Task { await logger.log("Failed to locate bundled vocabulary dataset", level: .error, category: "VocabStore") }
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let rawDataset = try JSONDecoder().decode(RawDataset.self, from: data)
            let entries = rawDataset.items.map { item in
                Entry(className: item.className, english: item.english, spanish: item.spanish, french: item.french)
            }

            Task { await logger.log("Loaded \(entries.count) vocabulary entries", level: .info, category: "VocabStore") }

            return Dictionary(uniqueKeysWithValues: entries.map { ($0.normalizedClassName, $0) })
        } catch {
            Task {
                await logger.log(
                    "Failed to decode vocabulary dataset: \(error.localizedDescription)",
                    level: .error,
                    category: "VocabStore"
                )
            }
            return [:]
        }
    }

    // Common label aliases found across model variants; map to COCO names used in the dataset
    private static let aliases: [String: String] = [
        "sofa": "couch",
        "tvmonitor": "tv",
        "tv monitor": "tv",
        "television": "tv",
        "cellphone": "cell phone",
        "mobile phone": "cell phone",
        "diningtable": "dining table",
        "pottedplant": "potted plant",
        "hair dryer": "hair drier",
        "teddy": "teddy bear",
        "wineglass": "wine glass",
        "sportsball": "sports ball",
        "hotdog": "hot dog",
    ]
}

private extension String {
    func normalizedKey() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
