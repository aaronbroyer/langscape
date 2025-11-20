#if canImport(SwiftUI)
import SwiftUI
import CoreVideo
import DetectionKit
import Utilities

@MainActor
final class ContextManager: ObservableObject {
    enum State: Equatable {
        case unknown
        case detecting
        case locked(String)
    }

    @Published private(set) var state: State = .unknown

    private let sceneClassifier: VLMDetector
    private var classifierPrepared = false
    private let detector: CombinedDetector
    private let logger: Utilities.Logger

    init(detector: CombinedDetector, logger: Utilities.Logger = .shared) {
        self.sceneClassifier = VLMDetector(logger: logger)
        self.detector = detector
        self.logger = logger
    }

    var shouldClassifyScene: Bool {
        if case .locked = state { return false }
        return true
    }

    var contextDisplayName: String {
        switch state {
        case .unknown:
            return "Detecting environment…"
        case .detecting:
            return "Locking environment…"
        case .locked(let value):
            return "Context: \(value.capitalized)"
        }
    }

    var isDetecting: Bool {
        if case .detecting = state { return true }
        return false
    }

    var canManuallyChange: Bool {
        if case .locked = state { return true }
        return false
    }

    func reset() {
        state = .unknown
    }

    func classify(_ pixelBuffer: CVPixelBuffer) async {
        guard case .unknown = state else { return }
        state = .detecting
        do {
            if !classifierPrepared {
                try await sceneClassifier.prepare()
                classifierPrepared = true
            }
            let sensed = await sceneClassifier.classifyScene(pixelBuffer: pixelBuffer)
            let normalized = sensed.isEmpty ? "general" : sensed
            let loaded = await detector.loadContext(normalized)
            if loaded {
                state = .locked(normalized)
                await logger.log("Context locked: \(normalized)", level: .info, category: "LangscapeApp.Context")
            } else {
                state = .unknown
            }
        } catch {
            state = .unknown
            await logger.log("Context classification failed: \(error.localizedDescription)", level: .error, category: "LangscapeApp.Context")
        }
    }
}
#endif
