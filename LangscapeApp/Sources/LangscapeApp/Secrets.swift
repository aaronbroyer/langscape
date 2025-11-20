#if canImport(Foundation)
import Foundation

enum Secrets {
    /// Gemini 1.5 Flash API key used by `VLMReferee` for cloud adjudication.
    /// TODO: Move into a secure storage mechanism before shipping.
    static let geminiAPIKey = "AIzaSyBqRvJljtywmDqm-UCIs-vXahPScp6wpo8"
}
#endif
