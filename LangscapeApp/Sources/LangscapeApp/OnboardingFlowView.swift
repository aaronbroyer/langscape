#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import DesignSystem
import UIComponents
import Utilities
#if canImport(UIKit)
import UIKit
#endif

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onComplete: () -> Void

    @State private var currentSlideIndex = 0
    @State private var hasTriggeredCompletion = false

    var body: some View {
        ZStack {
            ColorPalette.background.swiftUIColor
                .ignoresSafeArea()

            switch viewModel.step {
            case .splash:
                SplashScreen()
                    .task { await triggerSplashAdvance() }
            case .slides:
                IntroSlidesView(
                    slides: viewModel.slides,
                    currentIndex: $currentSlideIndex,
                    nextAction: advanceSlides,
                    finishAction: viewModel.showLanguageSelection
                )
            case .languageSelection:
                LanguageSelectionView(selectLanguage: viewModel.selectLanguage)
            case .cameraPermission:
                CameraPermissionView(
                    onAuthorized: handleCompletion,
                    viewModel: viewModel
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.step)
    }

    private func triggerSplashAdvance() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await MainActor.run { viewModel.advanceFromSplash() }
    }

    private func advanceSlides() {
        withAnimation {
            if currentSlideIndex < viewModel.slides.count - 1 {
                currentSlideIndex += 1
            } else {
                viewModel.showLanguageSelection()
            }
        }
    }

    private func handleCompletion() {
        guard !hasTriggeredCompletion else { return }
        hasTriggeredCompletion = true
        onComplete()
    }
}

private struct SplashScreen: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Langscape")
                .font(Typography.title.font.weight(.bold))
                .foregroundStyle(ColorPalette.primary.swiftUIColor)
            Spacer()
        }
    }
}

private struct IntroSlidesView: View {
    let slides: [OnboardingViewModel.Slide]
    @Binding var currentIndex: Int
    let nextAction: () -> Void
    let finishAction: () -> Void

    var body: some View {
        VStack(spacing: Spacing.large.cgFloat) {
            TabView(selection: $currentIndex) {
                ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                    SlideContent(slide: slide)
                        .tag(index)
                        .padding(.horizontal, Spacing.large.cgFloat)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: Spacing.xSmall.cgFloat) {
                ForEach(0..<slides.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? ColorPalette.primary.swiftUIColor : ColorPalette.primary.swiftUIColor.opacity(0.2))
                        .frame(width: 8, height: 8)
                }
            }

            PrimaryButton(title: currentIndex == slides.count - 1 ? "Get Started" : "Next") {
                if currentIndex == slides.count - 1 {
                    finishAction()
                } else {
                    nextAction()
                }
            }
            .padding(.horizontal, Spacing.large.cgFloat)
        }
    }

    private struct SlideContent: View {
        let slide: OnboardingViewModel.Slide

        var body: some View {
            VStack(spacing: Spacing.large.cgFloat) {
                Image(systemName: slide.systemImageName)
                    .font(.system(size: 80, weight: .semibold))
                    .foregroundStyle(ColorPalette.accent.swiftUIColor)
                    .padding()
                    .background(
                        Circle()
                            .fill(ColorPalette.primary.swiftUIColor.opacity(0.08))
                    )

                VStack(spacing: Spacing.small.cgFloat) {
                    Text(slide.title)
                        .font(Typography.title.font)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)

                    Text(slide.subtitle)
                        .font(Typography.body.font)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LanguageSelectionView: View {
    let selectLanguage: (LanguagePreference) -> Void

    var body: some View {
        VStack(spacing: Spacing.large.cgFloat) {
            Spacer()
            Text("Choose your target language")
                .font(Typography.title.font)
                .foregroundStyle(ColorPalette.primary.swiftUIColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.large.cgFloat)

            VStack(spacing: Spacing.medium.cgFloat) {
                ForEach(LanguagePreference.allCases) { preference in
                    Button(action: { selectLanguage(preference) }) {
                        VStack(alignment: .leading, spacing: Spacing.xSmall.cgFloat) {
                            Text(preference.title)
                                .font(Typography.body.font.weight(.semibold))
                                .foregroundStyle(ColorPalette.primary.swiftUIColor)
                            Text(preference.detail)
                                .font(Typography.caption.font)
                                .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(Spacing.medium.cgFloat)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(ColorPalette.primary.swiftUIColor.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 12, x: 0, y: 10)
                    .padding(.horizontal, Spacing.large.cgFloat)
                }
            }
            Spacer()
        }
    }
}

private struct CameraPermissionView: View {
    let onAuthorized: () -> Void
    @ObservedObject var viewModel: OnboardingViewModel

    @State private var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isRequesting = false
    @State private var hasCompleted = false

    var body: some View {
        VStack(spacing: Spacing.large.cgFloat) {
            Spacer()

            VStack(spacing: Spacing.small.cgFloat) {
                Text("Enable Camera Access")
                    .font(Typography.title.font)
                    .foregroundStyle(ColorPalette.primary.swiftUIColor)
                Text("Langscape needs the camera to identify objects around you.")
                    .font(Typography.body.font)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.7))
                    .padding(.horizontal, Spacing.large.cgFloat)
            }

            if status == .denied || status == .restricted {
                TranslucentPanel(cornerRadius: 24) {
                    VStack(spacing: Spacing.small.cgFloat) {
                        Text("Camera access is needed to detect objects.")
                            .font(Typography.body.font)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(ColorPalette.primary.swiftUIColor)
                        Text("Please enable camera permissions in Settings to continue.")
                            .font(Typography.caption.font)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Spacing.large.cgFloat)
            }

            PrimaryButton(title: status == .denied ? "Open Settings" : "Allow Camera") {
                if status == .denied || status == .restricted {
                    openSettings()
                } else {
                    requestPermission()
                }
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .disabled(isRequesting)

            if isRequesting {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            Spacer()
        }
        .onAppear(perform: evaluateAuthorization)
        .onChange(of: status) { newStatus in
            guard !hasCompleted else { return }
            if newStatus == .authorized {
                completeFlow()
            }
        }
    }

    private func evaluateAuthorization() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            completeFlow()
        }
    }

    private func requestPermission() {
        isRequesting = true
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                isRequesting = false
                status = AVCaptureDevice.authorizationStatus(for: .video)
                if granted {
                    completeFlow()
                }
            }
        }
    }

    private func completeFlow() {
        guard !hasCompleted else { return }
        hasCompleted = true
        viewModel.completeOnboarding()
        onAuthorized()
    }

    private func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

#if DEBUG
#Preview("Onboarding Flow") {
    if let defaults = UserDefaults(suiteName: "com.langscape.preview.onboarding") {
        defaults.removePersistentDomain(forName: "com.langscape.preview.onboarding")
        let settings = AppSettings(userDefaults: defaults)
        settings.reset()
        return OnboardingFlowView(viewModel: OnboardingViewModel(settings: settings)) {}
            .environmentObject(settings)
    } else {
        return OnboardingFlowView(viewModel: OnboardingViewModel()) {}
            .environmentObject(AppSettings.shared)
    }
}
#endif
#endif
