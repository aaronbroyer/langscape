import Foundation
import SentencepieceTokenizer

enum SentencePieceTokenizerError: Swift.Error {
    case tokenizationFailed(String)
}

struct SentencePieceTokenizer {
    private let tokenizer: SentencepieceTokenizer

    init(modelURL: URL) throws {
        do {
            tokenizer = try SentencepieceTokenizer(modelPath: modelURL.path, tokenOffset: 0)
        } catch {
            throw SentencePieceTokenizerError.tokenizationFailed(error.localizedDescription)
        }
    }

    func encode(_ text: String) throws -> [Int] {
        do {
            return try tokenizer.encode(text)
        } catch {
            throw SentencePieceTokenizerError.tokenizationFailed(error.localizedDescription)
        }
    }

    func idToToken(_ id: Int) throws -> String {
        do {
            return try tokenizer.idToToken(id)
        } catch {
            throw SentencePieceTokenizerError.tokenizationFailed(error.localizedDescription)
        }
    }

    func tokenToId(_ token: String) -> Int {
        tokenizer.tokenToId(token)
    }

    func decode(_ ids: [Int]) throws -> String {
        do {
            return try tokenizer.decode(ids)
        } catch {
            throw SentencePieceTokenizerError.tokenizationFailed(error.localizedDescription)
        }
    }
}
