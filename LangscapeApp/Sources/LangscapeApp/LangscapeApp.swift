#if canImport(SwiftUI)
import SwiftUI
import DetectionKit
import Utilities

@main
struct LangscapeAppMain: App {
    @StateObject private var detectionViewModel: DetectionVM
    @StateObject private var appSettings: AppSettings

    init() {
        let service = CombinedDetector(geminiAPIKey: Secrets.geminiAPIKey)
        let settings = AppSettings.shared
        _appSettings = StateObject(wrappedValue: settings)
        _detectionViewModel = StateObject(
            wrappedValue: DetectionVM(
                settings: settings,
                objectDetector: service
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            AppFlowView(
                detectionViewModel: detectionViewModel
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

    @State private var path: [Route] = []
    @StateObject private var onboardingViewModel = OnboardingViewModel()

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingFlowView(viewModel: onboardingViewModel) {
                transitionToExperience()
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .experience:
                    CameraPreviewView(
                        viewModel: detectionViewModel
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
        onboardingViewModel.resetFlow()
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
