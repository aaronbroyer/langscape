import SwiftUI
import DesignSystem
import UIComponents
import Utilities
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct OnboardingFlowView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            switch viewModel.step {
            case .splash:
                OnboardingSplashScreen()
                    .transition(.opacity)
                    .onAppear { viewModel.scheduleAutomaticSplashAdvance() }
            case .hero:
                OnboardingHeroScreen {
                    viewModel.getStartedFromHero()
                }
                .transition(.opacity)
            case .languageSelection:
                OnboardingLanguageSelectionScreen(
                    targetLanguage: viewModel.targetLanguage,
                    nativeLanguage: viewModel.nativeLanguage,
                    onTapTargetLanguage: { viewModel.setTargetLanguage(viewModel.targetLanguage.opposite) },
                    onTapNativeLanguage: { viewModel.setNativeLanguage(viewModel.nativeLanguage.opposite) },
                    onContinue: { viewModel.continueFromLanguageSelection() },
                    onNotNow: { viewModel.skipLanguageSelection() }
                )
                .transition(.opacity)
            case .cameraPermission:
                OnboardingCameraPermissionScreen(
                    onEnableCamera: {
                        Task {
                            await viewModel.requestCameraAccess()
                            viewModel.completeOnboarding()
                            onComplete()
                        }
                    },
                    onNotNow: {
                        viewModel.completeOnboarding()
                        onComplete()
                    }
                )
                .transition(.opacity)
            case .done:
                // In practice AppFlowView will immediately navigate.
                ProgressView().onAppear { onComplete() }
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: viewModel.step)
    }
}

private struct OnboardingSplashScreen: View {
    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    LangscapeLogo(style: .mark, glyphSize: 88)
                        .shadow(color: OnboardingVisuals.accent.opacity(0.22), radius: 16, x: 0, y: 10)

                    Text("langscape")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))

                    Text("Language, layered onto life.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .padding(.bottom, 68)

                Spacer()

                OnboardingGlowLine()
                    .padding(.bottom, 86)
            }
            .padding(.horizontal, 28)
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingHeroScreen: View {
    var onGetStarted: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OnboardingHeroBackdrop()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.70),
                        Color.black.opacity(0.35),
                        Color.black.opacity(0.80)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                OnboardingNoiseOverlay(opacity: 0.10)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    OnboardingHeroTitle()
                        .padding(.top, 62)

                    Spacer()

                    OnboardingPillButton(
                        title: "Get started →",
                        style: .outlined,
                        action: onGetStarted
                    )
                    .padding(.bottom, 78)
                }
                .padding(.horizontal, 28)

                OnboardingLabelChip(text: "Window")
                    .position(
                        x: proxy.size.width * 0.72,
                        y: proxy.size.height * 0.30
                    )

                OnboardingLabelChip(text: "Couch")
                    .position(
                        x: proxy.size.width * 0.42,
                        y: proxy.size.height * 0.46
                    )
            }
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingHeroTitle: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("See the world")
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            HStack(spacing: 0) {
                Text("in")
                    .foregroundStyle(OnboardingVisuals.accent)
                Text(" a new language")
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .font(.system(size: 34, weight: .medium, design: .rounded))
        }
        .multilineTextAlignment(.center)
    }
}

private struct OnboardingLanguageSelectionScreen: View {
    let targetLanguage: OnboardingViewModel.Language
    let nativeLanguage: OnboardingViewModel.Language
    let onTapTargetLanguage: () -> Void
    let onTapNativeLanguage: () -> Void
    let onContinue: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    Text("Choose your\nlanguages")
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 14) {
                        OnboardingFieldLabel("Target language")

                        OnboardingLanguageRow(
                            flag: targetLanguage.flag,
                            languageName: targetLanguage.displayName,
                            action: onTapTargetLanguage
                        )

                        Spacer().frame(height: 10)

                        OnboardingFieldLabel("Native language")

                        OnboardingLanguageRow(
                            flag: nativeLanguage.flag,
                            languageName: nativeLanguage.displayName,
                            action: onTapNativeLanguage
                        )
                    }
                    .frame(maxWidth: 420)
                    .padding(.top, 6)

                    VStack(spacing: 14) {
                        OnboardingPillButton(title: "Continue", style: .filled, action: onContinue)

                        Button(action: onNotNow) {
                            Text("Not now")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingCameraPermissionScreen: View {
    let onEnableCamera: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    OnboardingCameraIcon()

                    VStack(spacing: 12) {
                        Text("Turn your camera\ninto a")
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.92))

                        Text("language lens")
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundStyle(OnboardingVisuals.accent)
                    }
                    .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        Text("We use your camera to label real-\nworld objects.")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .multilineTextAlignment(.center)

                        Text("No photos are stored.")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    .padding(.top, 2)

                    VStack(spacing: 14) {
                        OnboardingPillButton(title: "Enable Camera", style: .filled, action: onEnableCamera)

                        Button(action: onNotNow) {
                            Text("Not now")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 14)
                }
                .frame(maxWidth: 480)

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingCameraIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "camera")
                .font(.system(size: 74, weight: .ultraLight))
                .foregroundStyle(OnboardingVisuals.accent.opacity(0.55))

            LangscapeLogo(style: .mark, glyphSize: 56)
                .shadow(color: OnboardingVisuals.accent.opacity(0.20), radius: 10, x: 0, y: 6)
        }
        .padding(.bottom, 6)
    }
}

private struct OnboardingFieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.70))
            .padding(.horizontal, 6)
    }
}

private struct OnboardingLanguageRow: View {
    let flag: String
    let languageName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(flag)
                    .font(.system(size: 20))

                Text(languageName)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(OnboardingVisuals.accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: OnboardingVisuals.accent.opacity(0.10), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct OnboardingLabelChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.26))
            )
            .overlay(
                Capsule()
                    .strokeBorder(OnboardingVisuals.accent.opacity(0.60), lineWidth: 1.5)
            )
            .shadow(color: OnboardingVisuals.accent.opacity(0.32), radius: 18, x: 0, y: 10)
    }
}

private struct OnboardingGlowLine: View {
    var body: some View {
        Capsule(style: .circular)
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        OnboardingVisuals.accent.opacity(0.85),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(maxWidth: 320, maxHeight: 2)
            .shadow(color: OnboardingVisuals.accent.opacity(0.55), radius: 10, x: 0, y: 0)
            .shadow(color: OnboardingVisuals.accent.opacity(0.35), radius: 24, x: 0, y: 0)
    }
}

private struct OnboardingPillButton: View {
    enum Style {
        case filled
        case outlined
    }

    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.vertical, 16)
                .frame(maxWidth: 340)
                .frame(height: 54)
        }
        .buttonStyle(.plain)
        .background(background)
        .overlay(border)
        .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .filled:
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            OnboardingVisuals.accent.opacity(0.55),
                            OnboardingVisuals.accent.opacity(0.78)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.12),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        case .outlined:
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .fill(OnboardingVisuals.accent.opacity(0.12))
                )
        }
    }

    private var border: some View {
        Capsule()
            .strokeBorder(borderColor, lineWidth: 1.25)
    }

    private var borderColor: Color {
        switch style {
        case .filled:
            return Color.white.opacity(0.16)
        case .outlined:
            return OnboardingVisuals.accent.opacity(0.55)
        }
    }

    private var shadowColor: Color {
        switch style {
        case .filled:
            return OnboardingVisuals.accent.opacity(0.34)
        case .outlined:
            return OnboardingVisuals.accent.opacity(0.22)
        }
    }
}

private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    OnboardingVisuals.backgroundTop,
                    OnboardingVisuals.backgroundBottom
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    OnboardingVisuals.accent.opacity(0.14),
                    Color.clear
                ],
                center: .bottom,
                startRadius: 0,
                endRadius: 520
            )
            .ignoresSafeArea()

            OnboardingNoiseOverlay(opacity: 0.14)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.92)
                ],
                center: .center,
                startRadius: 120,
                endRadius: 900
            )
            .ignoresSafeArea()
        }
    }
}

private enum OnboardingVisuals {
    static let accent = Color(red: 0.66, green: 0.85, blue: 0.86)
    static let backgroundTop = Color(red: 0.05, green: 0.06, blue: 0.07)
    static let backgroundBottom = Color(red: 0.02, green: 0.03, blue: 0.04)
}

private struct OnboardingNoiseOverlay: View {
    let opacity: Double

    var body: some View {
        #if canImport(CoreGraphics)
        Image(decorative: OnboardingNoiseTexture.image, scale: 1)
            .resizable(resizingMode: .tile)
            .interpolation(.none)
            .blendMode(.overlay)
            .opacity(opacity)
        #else
        Color.clear
        #endif
    }
}

private enum OnboardingNoiseTexture {
    #if canImport(CoreGraphics)
    static let image: CGImage = {
        let width = 256
        let height = 256
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var generator = SeededRandomGenerator(seed: 0xC0FFEE)
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let gray = UInt8.random(in: 0...255, using: &generator)
            let alpha = UInt8.random(in: 0...38, using: &generator)

            pixels[index] = gray
            pixels[index + 1] = gray
            pixels[index + 2] = gray
            pixels[index + 3] = alpha
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }()
    #endif
}

private struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private struct OnboardingHeroBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.12, blue: 0.15),
                        Color(red: 0.05, green: 0.05, blue: 0.07)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.72, blue: 0.45).opacity(0.78),
                                Color(red: 0.26, green: 0.44, blue: 0.78).opacity(0.62)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size.width * 0.35, height: size.height * 0.44)
                    .position(x: size.width * 0.26, y: size.height * 0.38)
                    .blur(radius: 0.35)
                    .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 16)

                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.18, blue: 0.22).opacity(0.95))
                    .frame(width: size.width * 0.76, height: size.height * 0.22)
                    .position(x: size.width * 0.50, y: size.height * 0.62)
                    .shadow(color: Color.black.opacity(0.45), radius: 30, x: 0, y: 22)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .frame(width: size.width * 0.32, height: size.height * 0.16)
                    .position(x: size.width * 0.74, y: size.height * 0.42)
                    .shadow(color: Color.black.opacity(0.35), radius: 20, x: 0, y: 14)
            }
            .blur(radius: 0.25)
        }
    }
}
