import Foundation
import Utilities

public protocol LLMClient: Sendable {
    func send(prompt: String) async throws -> String
}

public enum LLMClientError: Swift.Error, Equatable {
    case missingAPIKey
    case invalidResponse
    case requestFailed(String)
}

public struct LangscapeLLM: LLMClient {
    private let client: GeminiClient?
    private let logger: Logger

    public init(apiKey: String? = nil, model: String = "gemini-1.5-pro", logger: Logger = .shared) {
        self.logger = logger
        let resolvedKey = apiKey ?? EnvLoader.value(for: "GEMINI_API_KEY")
        if let resolvedKey, !resolvedKey.isEmpty {
            self.client = GeminiClient(apiKey: resolvedKey, model: model, logger: logger)
        } else {
            self.client = nil
        }
    }

    public func send(prompt: String) async throws -> String {
        guard let client else {
            await logger.log("Missing GEMINI_API_KEY; cannot send LLM prompt.", level: .warning, category: "LLMKit")
            throw LLMClientError.missingAPIKey
        }
        return try await client.send(prompt: prompt)
    }
}

private struct GeminiClient: Sendable {
    private let apiKey: String
    private let model: String
    private let logger: Logger

    init(apiKey: String, model: String, logger: Logger) {
        self.apiKey = apiKey
        self.model = model
        self.logger = logger
    }

    func send(prompt: String) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            throw LLMClientError.requestFailed("Invalid Gemini URL.")
        }

        let jsonBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 64
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw LLMClientError.requestFailed("Gemini responded with status \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.compactMap(\.text).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await logger.log("Gemini returned no text response.", level: .error, category: "LLMKit")
            throw LLMClientError.invalidResponse
        }
        return text
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }
}

private enum EnvLoader {
    private static let values: [String: String] = {
        var resolved = ProcessInfo.processInfo.environment

        if let fileValues = loadDotEnv() {
            for (key, value) in fileValues where resolved[key]?.isEmpty ?? true {
                resolved[key] = value
            }
        }

        return resolved
    }()

    static func value(for key: String) -> String? {
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
                if !key.isEmpty, !value.isEmpty {
                    result[key] = value
                }
            }
        return result.isEmpty ? nil : result
    }

    #if DEBUG
    private static func dotEnvURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        var url = URL(fileURLWithPath: #filePath)
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
