import Foundation

public struct LoggedError: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let message: String
    public let metadata: [String: String]

    public init(id: UUID = UUID(), date: Date = Date(), message: String, metadata: [String: String] = [:]) {
        self.id = id
        self.date = date
        self.message = message
        self.metadata = metadata
    }
}

public actor ErrorStore {
    public static let shared = ErrorStore()

    public let capacity: Int
    private var errors: [LoggedError]

    public init(capacity: Int = 50) {
        self.capacity = capacity
        self.errors = []
    }

    public func add(_ error: LoggedError) {
        errors.insert(error, at: 0)
        if errors.count > capacity {
            errors.removeLast(errors.count - capacity)
        }
    }

    public func allErrors() -> [LoggedError] {
        errors
    }

    public func clear() {
        errors.removeAll()
    }
}
