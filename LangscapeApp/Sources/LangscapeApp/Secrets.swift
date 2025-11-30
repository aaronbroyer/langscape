import Foundation

enum Secrets {
    /// Gemini 1.5 Flash API key used by `VLMReferee` for cloud adjudication.
    /// Looked up from the environment or optional `.env` file so the value is never committed.
    static let geminiAPIKey: String = {
        guard let token = EnvLoader.shared["GEMINI_API_KEY"], !token.isEmpty else {
            assertionFailure("Missing GEMINI_API_KEY. Add it to your environment or .env file.")
            return ""
        }
        return token
    }()
}

private final class EnvLoader {
    static let shared = EnvLoader()

    private let values: [String: String]

    private init() {
        var resolved = ProcessInfo.processInfo.environment

        if let fileValues = EnvLoader.loadDotEnv() {
            for (key, value) in fileValues where resolved[key]?.isEmpty ?? true {
                resolved[key] = value
            }
        }

        self.values = resolved
    }

    subscript(key: String) -> String? {
        values[key]
    }

    private static func loadDotEnv() -> [String: String]? {
        guard let url = dotEnvURL(),
              let raw = try? String(contentsOf: url) else {
            return nil
        }

        var result: [String: String] = [:]
        raw
            .split(whereSeparator: \.isNewline)
            .forEach { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      let separatorIndex = trimmed.firstIndex(of: "=") else { return }
                let key = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
                let valueIndex = trimmed.index(after: separatorIndex)
                let value = String(trimmed[valueIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty && !value.isEmpty {
                    result[key] = value
                }
            }
        return result.isEmpty ? nil : result
    }

    #if DEBUG
    private static func dotEnvURL() -> URL? {
        // First attempt to find a bundled .env resource (only present if the developer adds it to the target).
        if let bundled = Bundle.main.url(forResource: ".env", withExtension: nil) {
            return bundled
        }

        // Fallback: derive repository root from the compile-time path of this file.
        var url = URL(fileURLWithPath: #filePath)
        // .../LangscapeApp/Sources/LangscapeApp/Secrets.swift -> ascend 3x to repo root.
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent(".env")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }
    #else
    private static func dotEnvURL() -> URL? { Bundle.main.url(forResource: ".env", withExtension: nil) }
    #endif
}
