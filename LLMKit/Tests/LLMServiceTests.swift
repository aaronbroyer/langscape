import XCTest
@testable import LLMKit
import Utilities

final class LLMServiceTests: XCTestCase {
    func testCachesResponses() async throws {
        let client = StubClient(response: "la mesa")
        let service = LLMService(client: client)

        let first = try await service.translate("table", from: .english, to: .spanish)
        XCTAssertEqual(first, "la mesa")

        let second = try await service.translate("table", from: .english, to: .spanish)
        XCTAssertEqual(second, "la mesa")

        let promptCount = await client.promptCount()
        XCTAssertEqual(promptCount, 1)
    }

    func testFallsBackWhenModelMissing() async throws {
        let client = StubClient(response: "ignored")
        let missingBundle = Bundle(for: MissingManifestMarker.self)
        let service = LLMService(client: client, bundle: missingBundle)

        let translated = try await service.translate("tree", from: .english, to: .spanish)
        XCTAssertEqual(translated, "el/la tree")
    }

    func testThrowsForEmptyInput() async {
        let client = StubClient(response: "ignored")
        let service = LLMService(client: client)

        do {
            _ = try await service.translate("   ", from: .english, to: .spanish)
            XCTFail("Expected empty input error")
        } catch let error as LLMService.Error {
            XCTAssertEqual(error, .emptyInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class MissingManifestMarker {}

private actor StubClient: LLMClient {
    private(set) var prompts: [String] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func send(prompt: String) async -> String {
        prompts.append(prompt)
        return response
    }

    func promptCount() async -> Int {
        prompts.count
    }
}
