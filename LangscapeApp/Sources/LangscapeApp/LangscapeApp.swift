#if canImport(SwiftUI)
import SwiftUI
import DetectionKit

@main
struct LangscapeAppMain: App {
    @StateObject private var detectionViewModel = DetectionVM(service: YOLOInterpreter())

    var body: some Scene {
        WindowGroup {
            CameraPreviewView(viewModel: detectionViewModel)
        }
    }
}
#endif
