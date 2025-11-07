#if canImport(SwiftUI)
import SwiftUI
import DetectionKit
import GameKitLS

@main
struct LangscapeAppMain: App {
    @StateObject private var detectionViewModel: DetectionVM
    @StateObject private var labelScrambleViewModel: LabelScrambleVM

    init() {
        let detectionVM = DetectionVM(service: YOLOInterpreter())
        _detectionViewModel = StateObject(wrappedValue: detectionVM)

        let scrambleVM = LabelScrambleVM()
        _labelScrambleViewModel = StateObject(wrappedValue: scrambleVM)
    }

    var body: some Scene {
        WindowGroup {
            CameraPreviewView(viewModel: detectionViewModel, gameViewModel: labelScrambleViewModel)
        }
    }
}
#endif
