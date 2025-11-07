import SwiftUI
import Utilities
import UIComponents

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onComplete: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            switch viewModel.step {
            case .splash:
                VStack(spacing: 24) {
                    LangscapeLogo(style: .full, glyphSize: 64)
                    Button("Get Started") { viewModel.advanceFromSplash() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            case .slides:
                VStack(spacing: 20) {
                    LangscapeLogo(style: .mark, glyphSize: 52)
                    Text("Learn by labeling what you see.")
                        .font(.title2)
                        .multilineTextAlignment(.center)
                    Button("Choose Language") { viewModel.showLanguageSelection() }
                        .buttonStyle(.borderedProminent)
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
                VStack(spacing: 20) {
                    LangscapeLogo(style: .mark, glyphSize: 52)
                    Text("Camera Access")
                        .font(.title2)
                    Text("We use the camera to detect objects for activities.")
                        .multilineTextAlignment(.center)
                    Button("Continue") {
                        viewModel.completeOnboarding()
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            case .done:
                // In practice AppFlowView will immediately navigate.
                ProgressView().onAppear { onComplete() }
            }
        }
    }
}
