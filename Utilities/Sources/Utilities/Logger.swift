import Foundation

public protocol LogDestination: Sendable {
    func write(_ message: String)
}

public struct ConsoleDestination: LogDestination {
    public init() {}

    public func write(_ message: String) {
        print(message)
    }
}

public actor Logger {
    public enum Level: String, Sendable {
        case debug
        case info
        case warning
        case error
    }

    public static let shared = Logger()

    private var destinations: [LogDestination]
    private let dateFormatter: DateFormatter

    public init(destinations: [LogDestination] = [ConsoleDestination()]) {
        self.destinations = destinations
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        self.dateFormatter = formatter
    }

    public func addDestination(_ destination: LogDestination) {
        destinations.append(destination)
    }

    public func log(_ message: @autoclosure @Sendable () -> String, level: Level = .info, category: String? = nil) {
        let timestamp = dateFormatter.string(from: Date())
        var composed = "[\(timestamp)] [\(level.rawValue.uppercased())]"
        if let category {
            composed += " [\(category)]"
        }
        composed += " \(message())"

        for destination in destinations {
            destination.write(composed)
        }
    }
}
