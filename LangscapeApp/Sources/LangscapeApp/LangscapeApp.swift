#if canImport(SwiftUI)
import SwiftUI
import DetectionKit
import GameKitLS
import Utilities

private enum Secrets {
    static let geminiAPIKey = "AIzaSyBqRvJljtywmDqm-UCIs-vXahPScp6wpo8"
}

@main
struct LangscapeAppMain: App {
    @StateObject private var detectionViewModel: DetectionVM
    @StateObject private var labelScrambleViewModel: LabelScrambleVM
    @StateObject private var appSettings: AppSettings
    @StateObject private var contextManager: ContextManager

    init() {
        let service = CombinedDetector(geminiAPIKey: Secrets.geminiAPIKey)
        let detectionVM = DetectionVM(
            service: service,
            throttleInterval: 0.08,
            geminiAPIKey: Secrets.geminiAPIKey
        )
        _detectionViewModel = StateObject(wrappedValue: detectionVM)

        let scrambleVM = LabelScrambleVM()
        _labelScrambleViewModel = StateObject(wrappedValue: scrambleVM)

        _appSettings = StateObject(wrappedValue: AppSettings.shared)
        _contextManager = StateObject(wrappedValue: ContextManager(detector: service))
    }

    var body: some Scene {
        WindowGroup {
            AppFlowView(
                detectionViewModel: detectionViewModel,
                gameViewModel: labelScrambleViewModel,
                contextManager: contextManager
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
    @ObservedObject var contextManager: ContextManager

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
                        gameViewModel: gameViewModel,
                        contextManager: contextManager
                    )
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            EmptyView()
                        }
                    }
                }
            }
        }
        .onAppear(perform: configureInitialRoute)
        .onChange(of: settings.hasCompletedOnboarding) { _, completed in
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
