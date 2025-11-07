import SwiftUI
import Utilities

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onComplete: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            switch viewModel.step {
            case .splash:
                VStack(spacing: 16) {
                    Text("Welcome to Langscape")
                        .font(.largeTitle)
                    Button("Get Started") { viewModel.advanceFromSplash() }
                }
                .padding()
            case .slides:
                VStack(spacing: 16) {
                    Text("Learn by labeling what you see.")
                        .font(.title2)
                    Button("Choose Language") { viewModel.showLanguageSelection() }
                }
                .padding()
            case .languageSelection:
                VStack(spacing: 16) {
                    Text("Choose your learning direction")
                    ForEach(LanguagePreference.allCases) { pref in
                        Button(pref.title) { viewModel.selectLanguage(pref) }
                    }
                }
                .padding()
            case .cameraPermission:
                VStack(spacing: 16) {
                    Text("Camera Access")
                        .font(.title2)
                    Text("We use the camera to detect objects for activities.")
                        .multilineTextAlignment(.center)
                    Button("Continue") {
                        viewModel.completeOnboarding()
                        onComplete()
                    }
                }
                .padding()
            case .done:
                // In practice AppFlowView will immediately navigate.
                ProgressView().onAppear { onComplete() }
            }
        }
    }
}

