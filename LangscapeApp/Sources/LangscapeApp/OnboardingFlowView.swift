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
                VStack(spacing: 28) {
                    LangscapeLogo(style: .full, glyphSize: 68, brand: .context)
                    CTAButton("Get Started") {
                        viewModel.advanceFromSplash()
                    }
                }
                .padding()
            case .slides:
                VStack(spacing: 22) {
                    LangscapeLogo(style: .mark, glyphSize: 56, brand: .context)
                    Text("Learn by labeling what you see.")
                        .font(.title2)
                        .multilineTextAlignment(.center)
                    CTAButton("Choose Language", systemImage: "character.book.closed") {
                        viewModel.showLanguageSelection()
                    }
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
                VStack(spacing: 22) {
                    LangscapeLogo(style: .mark, glyphSize: 56, brand: .context)
                    Text("Camera Access")
                        .font(.title2)
                    Text("We use the camera to detect objects for activities.")
                        .multilineTextAlignment(.center)
                    CTAButton("Continue", systemImage: "camera.viewfinder") {
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
