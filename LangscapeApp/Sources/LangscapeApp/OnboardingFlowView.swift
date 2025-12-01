import SwiftUI
import Utilities
import UIComponents
import DesignSystem

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onComplete: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            switch viewModel.step {
            case .splash:
                VStack(spacing: 28) {
                    LangscapeLogo(style: .full, glyphSize: 68)
                    CTAButton("Get Started") {
                        viewModel.advanceFromSplash()
                    }
                }
                .padding()
            case .slides:
                ZStack {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        VStack(spacing: Spacing.medium.cgFloat) {
                            LangscapeLogo(style: .mark, glyphSize: 72)
                                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 6)

                            Text("Language, layered on life")
                                .font(Typography.title.font.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(ColorPalette.primary.swiftUIColor)
                                .padding(.horizontal, Spacing.xLarge.cgFloat)
                        }
                        .frame(maxWidth: 480)

                        Spacer()

                        CTAButton("Choose Language") {
                            viewModel.showLanguageSelection()
                        }
                        .padding(.horizontal, Spacing.xLarge.cgFloat)
                        .padding(.bottom, Spacing.xLarge.cgFloat * 1.2)
                    }
                }
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
                    LangscapeLogo(style: .mark, glyphSize: 56)
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
