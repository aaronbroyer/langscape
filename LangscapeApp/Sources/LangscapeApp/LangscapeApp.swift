#if canImport(SwiftUI)
import SwiftUI
import DetectionKit
import GameKitLS
import Utilities

@main
struct LangscapeAppMain: App {
    @StateObject private var detectionViewModel: DetectionVM
    @StateObject private var labelScrambleViewModel: LabelScrambleVM
    @StateObject private var appSettings: AppSettings

    init() {
        let detectionVM = DetectionVM(service: YOLOInterpreter())
        _detectionViewModel = StateObject(wrappedValue: detectionVM)

        let scrambleVM = LabelScrambleVM()
        _labelScrambleViewModel = StateObject(wrappedValue: scrambleVM)

        _appSettings = StateObject(wrappedValue: AppSettings.shared)
    }

    var body: some Scene {
        WindowGroup {
            AppFlowView(
                detectionViewModel: detectionViewModel,
                gameViewModel: labelScrambleViewModel
            )
            .environmentObject(appSettings)
        }
    }
}

private struct AppFlowView: View {
    enum Route: Hashable {
        case experience
    }

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var detectionViewModel: DetectionVM
    @ObservedObject var gameViewModel: LabelScrambleVM

    @State private var path: [Route] = []
    @StateObject private var onboardingViewModel = OnboardingViewModel()

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingFlowView(viewModel: onboardingViewModel) {
                transitionToExperience()
            }
            .navigationBarBackButtonHidden(true)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .experience:
                    CameraPreviewView(
                        viewModel: detectionViewModel,
                        gameViewModel: gameViewModel
                    )
                    .navigationBarBackButtonHidden(true)
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .onAppear(perform: configureInitialRoute)
        .onChange(of: settings.hasCompletedOnboarding) { completed in
            if completed {
                transitionToExperience()
            }
        }
    }

    private func configureInitialRoute() {
        #if DEBUG
        // In Debug builds always start at onboarding to facilitate testing.
        settings.reset()
        path.removeAll()
        onboardingViewModel.step = .splash
        return
        #else
        if settings.hasCompletedOnboarding {
            transitionToExperience()
        }
        #endif
    }

    private func transitionToExperience() {
        if path != [.experience] {
            path = [.experience]
        }
    }
}
#endif
