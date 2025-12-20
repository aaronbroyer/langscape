#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import RealityKit
import DetectionKit
import GameKitLS
import UIComponents
import DesignSystem
import Utilities

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ImageIO)
import ImageIO
#endif

private typealias DetectionRect = DetectionKit.NormalizedRect

struct CameraPreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: DetectionVM

    @State private var showHomeOverlay = true
    @State private var homeCardPressed = false

    @StateObject private var motion = MotionManager()

    private var parallaxOffset: CGSize {
        CGSize(
            width: CGFloat(motion.roll) * 24,
            height: CGFloat(motion.pitch) * 24
        )
    }

    private var showsSnapshotLayer: Bool {
        switch viewModel.state {
        case .scanning, .playing, .summary:
            return viewModel.snapshot != nil
        default:
            return false
        }
    }

    private var showsMaskLayer: Bool {
        viewModel.state == .playing && viewModel.snapshot != nil && !viewModel.gameObjects.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ARCameraView(
                    viewModel: viewModel,
                    isFrameProcessingEnabled: !showHomeOverlay
                )
                .ignoresSafeArea()

                if showsSnapshotLayer, let snapshot = viewModel.snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .ignoresSafeArea()
                }

                if showsMaskLayer {
                    masksLayer
                        .offset(parallaxOffset)
                        .allowsHitTesting(false)
                }

                overlays(in: proxy.size)

                if viewModel.state == .scanning {
                    ScanningLaserView()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "experience")
            .background(Color.black)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    viewModel.resume()
                }
            }
        }
    }

    @ViewBuilder
    private func overlays(in size: CGSize) -> some View {
        ZStack {
            if showHomeOverlay {
                homeOverlay
            } else {
                switch viewModel.state {
                case .identifyingContext:
                    identifyingOverlay
                case .confirmContext:
                    confirmContextOverlay
                case .hunting:
                    huntingOverlay
                case .scanning:
                    scanningOverlay
                case .playing:
                    playingOverlay(in: size)
                case .summary:
                    summaryOverlay
                }
            }

            if viewModel.isPaused, viewModel.state == .playing, viewModel.overlay == nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                PauseOverlay(resumeAction: viewModel.resume, exitAction: exitToHome)
                    .transition(.scale.combined(with: .opacity))
            }

            if let overlay = viewModel.overlay {
                blockingOverlay(for: overlay)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: viewModel.state)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: viewModel.overlay)
    }

    private var homeOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.14).ignoresSafeArea())

            VStack(spacing: Spacing.large.cgFloat) {
                HStack(spacing: 16) {
                    LangscapeLogo(style: .mark, glyphSize: 62)
                    Text("langscape")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
                .padding(.top, Spacing.xLarge.cgFloat * 1.4)

                Spacer()

                VStack(spacing: Spacing.medium.cgFloat) {
                    Button(action: beginLabelScramble) {
                        HomeActivityCard(
                            iconName: "character.book.closed",
                            title: "Label Scramble",
                            subtitle: "Match words to what you see"
                        )
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(homeCardPressed ? 0.96 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: homeCardPressed)

                    HomeActivityCard(
                        iconName: "sparkles",
                        title: "More activities",
                        subtitle: "Coming soon",
                        enabled: false
                    )
                }
                .padding(Spacing.large.cgFloat)
                .background(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 36, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 12)
                .padding(.horizontal, Spacing.large.cgFloat)

                Spacer()
            }
            .padding(.bottom, Spacing.xLarge.cgFloat * 2.2)
        }
    }

    private var identifyingOverlay: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 24) {
                HStack(spacing: Spacing.small.cgFloat) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(ColorPalette.accent.swiftUIColor)
                    Text("Scanning room…")
                        .font(Typography.body.font.weight(.semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                }
                .padding(.horizontal, Spacing.large.cgFloat)
                .padding(.vertical, Spacing.medium.cgFloat)
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.bottom, Spacing.xLarge.cgFloat)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var confirmContextOverlay: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 28) {
                VStack(spacing: Spacing.medium.cgFloat) {
                    LangscapeLogo(style: .mark, glyphSize: 56)

                    Text("Is this a \(viewModel.detectedContext?.capitalized ?? "room")?")
                        .font(Typography.title.font.weight(.semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                        .multilineTextAlignment(.center)

                    HStack(spacing: Spacing.medium.cgFloat) {
                        Button(action: viewModel.retryContext) {
                            Text("Rescan")
                                .font(Typography.body.font.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.white.opacity(0.85))

                        PrimaryButton(title: "Yes") {
                            viewModel.confirmContext()
                        }
                    }
                }
                .padding(.horizontal, Spacing.large.cgFloat)
                .padding(.vertical, Spacing.large.cgFloat)
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.bottom, Spacing.xLarge.cgFloat)
        }
    }

    private var huntingOverlay: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 28) {
                VStack(spacing: Spacing.medium.cgFloat) {
                    Text("\(viewModel.liveObjectCount) Objects Found")
                        .font(Typography.title.font.weight(.semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)

                    PrimaryButton(title: "Play") {
                        viewModel.captureAndScan()
                    }
                }
                .padding(.horizontal, Spacing.large.cgFloat)
                .padding(.vertical, Spacing.large.cgFloat)
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.bottom, Spacing.xLarge.cgFloat)
        }
    }

    private var scanningOverlay: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 24) {
                HStack(spacing: Spacing.small.cgFloat) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(ColorPalette.accent.swiftUIColor)
                    Text("Scanning…")
                        .font(Typography.body.font.weight(.semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                }
                .padding(.horizontal, Spacing.large.cgFloat)
                .padding(.vertical, Spacing.medium.cgFloat)
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.bottom, Spacing.xLarge.cgFloat)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func playingOverlay(in size: CGSize) -> some View {
        if let round = viewModel.round {
            SnapshotRoundPlayLayer(
                round: round,
                placedLabels: viewModel.placedLabels,
                lastIncorrectLabelID: viewModel.lastIncorrectLabelID,
                interactive: !viewModel.isPaused,
                parallaxOffset: parallaxOffset,
                frameProvider: { object in boundingRect(for: object, in: size) },
                attemptMatch: viewModel.attemptMatch(labelID:on:),
                onPause: viewModel.pause
            )
        }
    }

    private var summaryOverlay: some View {
        VStack {
            Spacer()

            TranslucentPanel(cornerRadius: 24) {
                Text("Nice!")
                    .font(Typography.title.font.weight(.semibold))
                    .foregroundStyle(ColorPalette.primary.swiftUIColor)
                    .padding(.horizontal, Spacing.large.cgFloat)
                    .padding(.vertical, Spacing.medium.cgFloat)
            }
            .padding(.horizontal, Spacing.large.cgFloat)
            .padding(.bottom, Spacing.xLarge.cgFloat)
        }
        .allowsHitTesting(false)
    }

    private var masksLayer: some View {
        ZStack {
            ForEach(viewModel.gameObjects) { object in
                let outlineColor = object.isMatched ? ColorPalette.primary.swiftUIColor : ColorPalette.accent.swiftUIColor
                let glowColor = object.isMatched ? ColorPalette.primary.swiftUIColor : ColorPalette.accent.swiftUIColor
                let outlineOpacity = object.isMatched ? 0.22 : 0.75
                let glowOpacity = object.isMatched ? 0.12 : 0.45
                let innerGlowBlur: CGFloat = object.isMatched ? 6 : 10
                let outerGlowBlur: CGFloat = object.isMatched ? 12 : 20
                let glowShadow: CGFloat = object.isMatched ? 10 : 18

                let mask = Image(decorative: object.mask, scale: 1)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fill)

                ZStack {
                    mask
                        .foregroundStyle(glowColor)
                        .opacity(glowOpacity * 0.6)
                        .blur(radius: outerGlowBlur)
                        .blendMode(.screen)

                    mask
                        .foregroundStyle(glowColor)
                        .opacity(glowOpacity)
                        .blur(radius: innerGlowBlur)
                        .blendMode(.screen)

                    mask
                        .foregroundStyle(outlineColor)
                        .opacity(outlineOpacity)
                        .blendMode(.screen)
                }
                .compositingGroup()
                .shadow(color: glowColor.opacity(glowOpacity), radius: glowShadow, x: 0, y: 0)
                .ignoresSafeArea()
            }
        }
    }

    private func beginLabelScramble() {
        guard showHomeOverlay else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
            homeCardPressed = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            await MainActor.run {
                homeCardPressed = false
                showHomeOverlay = false
                viewModel.start()
            }
        }
    }

    private func exitToHome() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            showHomeOverlay = true
        }
        viewModel.exitToHome()
    }

    @ViewBuilder
    private func blockingOverlay(for overlay: DetectionVM.Overlay) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack {
                Spacer()

                TranslucentPanel(cornerRadius: 32) {
                    VStack(spacing: Spacing.medium.cgFloat) {
                        LangscapeLogo(style: .mark, glyphSize: 56)
                            .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 6)

                        switch overlay {
                        case .noObjects:
                            Text("No objects detected")
                                .font(Typography.title.font.weight(.semibold))
                                .foregroundStyle(ColorPalette.primary.swiftUIColor)

                            Text("Try pointing your camera at a scene with more objects.")
                                .font(Typography.body.font)
                                .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.8))
                                .multilineTextAlignment(.center)

                            PrimaryButton(title: "Back") {
                                viewModel.start()
                            }
                        case .fatal:
                            Text("We're having trouble")
                                .font(Typography.title.font.weight(.semibold))
                                .foregroundStyle(ColorPalette.primary.swiftUIColor)

                            Text("Something went wrong. Please restart Langscape.")
                                .font(Typography.body.font)
                                .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, Spacing.large.cgFloat)
                    .padding(.vertical, Spacing.large.cgFloat)
                }
                .padding(.horizontal, Spacing.large.cgFloat)

                Spacer()
            }
        }
        .allowsHitTesting(true)
    }

    private func boundingRect(for object: DetectedObject, in viewSize: CGSize) -> CGRect {
        if let mapped = projectedRect(for: object.boundingBox, inputImageSize: viewModel.inputImageSize, viewSize: viewSize) {
            return mapped
        }
        return object.boundingBox.rect(in: viewSize)
    }
}

private struct SnapshotRoundPlayLayer: View {
    let round: Round
    let placedLabels: Set<GameKitLS.Label.ID>
    let lastIncorrectLabelID: GameKitLS.Label.ID?
    let interactive: Bool
    let parallaxOffset: CGSize
    let frameProvider: (DetectedObject) -> CGRect
    let attemptMatch: (GameKitLS.Label.ID, UUID) -> LabelScrambleVM.MatchResult
    let onPause: () -> Void

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var frames: [DetectedObject.ID: CGRect] {
        Dictionary(
            round.objects.map { ($0.id, frameProvider($0)) },
            uniquingKeysWith: { _, new in new }
        )
    }

    private var placedLabelOverlays: [(label: GameKitLS.Label, frame: CGRect)] {
        round.labels.compactMap { label in
            guard placedLabels.contains(label.id), let frame = frames[label.objectID] else { return nil }
            return (label, frame)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(placedLabelOverlays, id: \.label.id) { entry in
                    StickyLabelOverlay(text: entry.label.text, frame: entry.frame)
                        .transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: placedLabels)
            }
            .offset(parallaxOffset)
            .allowsHitTesting(false)

            VStack {
                Spacer()

                TranslucentPanel(cornerRadius: 28) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(round.labels) { label in
                            let state = tokenState(for: label)
                            DraggableToken(
                                label: label,
                                state: state,
                                interactive: interactive,
                                dropHandler: { point in
                                    let compensated = CGPoint(
                                        x: point.x - parallaxOffset.width,
                                        y: point.y - parallaxOffset.height
                                    )
                                    guard let destinationID = destination(for: compensated) else { return .ignored }
                                    return attemptMatch(label.id, destinationID)
                                },
                                destinationAt: { point in
                                    let compensated = CGPoint(
                                        x: point.x - parallaxOffset.width,
                                        y: point.y - parallaxOffset.height
                                    )
                                    return destination(for: compensated)
                                }
                            )
                        }
                    }
                    .padding(.top, Spacing.small.cgFloat)
                    .padding(.bottom, Spacing.small.cgFloat)
                }
                .padding(.horizontal, Spacing.large.cgFloat)
                .padding(.bottom, Spacing.xLarge.cgFloat)
            }

            if interactive {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ColorPalette.primary.swiftUIColor)
                        .padding(Spacing.small.cgFloat)
                        .background(Color.white.opacity(0.8), in: Circle())
                        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
                }
                .padding(.top, 50)
                .padding(.trailing, Spacing.large.cgFloat)
            }
        }
    }

    private func tokenState(for label: GameKitLS.Label) -> LabelToken.VisualState {
        if placedLabels.contains(label.id) { return .placed }
        if lastIncorrectLabelID == label.id { return .incorrect }
        return .idle
    }

    private func destination(for point: CGPoint) -> DetectedObject.ID? {
        if let hit = frames.first(where: { expand(frame: $0.value).contains(point) })?.key {
            return hit
        }
        var best: (id: DetectedObject.ID, distance: CGFloat, frame: CGRect)?
        for (id, frame) in frames {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let dx = center.x - point.x
            let dy = center.y - point.y
            let d = sqrt(dx * dx + dy * dy)
            if best == nil || d < best!.distance { best = (id, d, frame) }
        }
        if let best {
            let radius = max(64, min(best.frame.width, best.frame.height) * 0.8)
            return best.distance <= radius ? best.id : nil
        }
        return nil
    }

    private func expand(frame: CGRect) -> CGRect {
        let inset = max(28, min(frame.width, frame.height) * 0.3)
        return frame.insetBy(dx: -inset, dy: -inset)
    }
}

private struct StickyLabelOverlay: View {
    let text: String
    let frame: CGRect

    var body: some View {
        Text(text)
            .font(Typography.caption.font.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(ColorPalette.primary.swiftUIColor)
            .padding(.horizontal, Spacing.medium.cgFloat)
            .padding(.vertical, Spacing.xSmall.cgFloat)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(ColorPalette.surface.swiftUIColor.opacity(0.75))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 5)
            .position(x: frame.midX, y: frame.midY)
    }
}

private struct DraggableToken: View {
    let label: GameKitLS.Label
    let state: LabelToken.VisualState
    let interactive: Bool
    let dropHandler: (CGPoint) -> LabelScrambleVM.MatchResult
    var destinationAt: ((CGPoint) -> DetectedObject.ID?)? = nil

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isNearTarget = false

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("experience"))
            LabelToken(text: label.text, state: state)
                .opacity(state == .placed ? 0 : 1)
                .scaleEffect(isDragging ? (isNearTarget ? 1.08 : 1.05) : 1)
                .offset(dragOffset)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: dragOffset)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: state)
                .allowsHitTesting(interactive && state != .placed)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard interactive, state != .placed else { return }
                            dragOffset = value.translation
                            isDragging = true
                            if let dest = destinationAt {
                                let dropPoint = CGPoint(
                                    x: frame.midX + value.translation.width,
                                    y: frame.midY + value.translation.height
                                )
                                isNearTarget = dest(dropPoint) != nil
                            }
                        }
                        .onEnded { value in
                            guard interactive, state != .placed else { return }
                            let dropPoint = CGPoint(
                                x: frame.midX + value.translation.width,
                                y: frame.midY + value.translation.height
                            )
                            let result = dropHandler(dropPoint)
                            #if canImport(UIKit)
                            let generator = UINotificationFeedbackGenerator()
                            generator.prepare()
                            switch result {
                            case .matched:
                                generator.notificationOccurred(.success)
                            case .mismatched:
                                generator.notificationOccurred(.error)
                            case .ignored:
                                generator.notificationOccurred(.warning)
                            default:
                                break
                            }
                            #endif
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                dragOffset = .zero
                                isDragging = false
                                isNearTarget = false
                            }
                        }
                )
                .onChange(of: state) { _, newState in
                    if newState == .placed {
                        dragOffset = .zero
                        isDragging = false
                        isNearTarget = false
                    }
                }
        }
        .frame(height: 56)
    }
}

private struct HomeActivityCard: View {
    let iconName: String
    let title: String
    let subtitle: String
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: Spacing.medium.cgFloat) {
            Image(systemName: iconName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ColorPalette.accent.swiftUIColor.opacity(enabled ? 1 : 0.4))

            VStack(alignment: .leading, spacing: Spacing.xSmall.cgFloat) {
                Text(title)
                    .font(Typography.body.font.weight(.semibold))
                    .foregroundStyle(ColorPalette.primary.swiftUIColor)

                Text(subtitle)
                    .font(Typography.caption.font)
                    .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.7))
            }

            Spacer()

            if enabled {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ColorPalette.primary.swiftUIColor.opacity(0.6))
            }
        }
        .padding(.vertical, Spacing.medium.cgFloat)
        .padding(.horizontal, Spacing.medium.cgFloat)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(ColorPalette.surface.swiftUIColor.opacity(enabled ? 0.35 : 0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .opacity(enabled ? 1 : 0.55)
    }
}

private extension DetectionRect {
    func rect(in size: CGSize) -> CGRect {
        let width = CGFloat(self.size.width) * size.width
        let height = CGFloat(self.size.height) * size.height
        let x = CGFloat(origin.x) * size.width
        let y = CGFloat(origin.y) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct ARCameraView: UIViewRepresentable {
    let viewModel: DetectionVM
    let isFrameProcessingEnabled: Bool

    func makeCoordinator() -> ARSessionCoordinator {
        ARSessionCoordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.isFrameProcessingEnabled = isFrameProcessingEnabled
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ARSessionCoordinator) {
        coordinator.detach(from: uiView)
        uiView.session.pause()
    }
}

private final class ARSessionCoordinator: NSObject, ARSessionDelegate {
    private let viewModel: DetectionVM
    private weak var arView: ARView?
    private var lastFrameTime: TimeInterval = 0
    private let captureInterval: TimeInterval = 0.08
    private let logger = Logger.shared

    var isFrameProcessingEnabled: Bool = false

    init(viewModel: DetectionVM) {
        self.viewModel = viewModel
    }

    @MainActor
    func attach(to arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Task { await logger.log("AR session configured", level: .info, category: "LangscapeApp.Camera") }
    }

    @MainActor
    func detach(from arView: ARView) {
        arView.session.delegate = nil
        self.arView = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isFrameProcessingEnabled else { return }

        let now = frame.timestamp
        guard now - lastFrameTime >= captureInterval else { return }
        lastFrameTime = now

        let capturedImage = frame.capturedImage
        let logger = logger
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            #if canImport(UIKit) && canImport(ImageIO)
            let orientationRawValue = await MainActor.run { () -> Int in
                self.arView?.window?.windowScene?.interfaceOrientation.rawValue ?? UIInterfaceOrientation.portrait.rawValue
            }
            let interfaceOrientation = UIInterfaceOrientation(rawValue: orientationRawValue) ?? .portrait
            let exifOrientation = exifOrientationForBackCamera(interfaceOrientation)
            let orientationRaw = exifOrientation.rawValue
            let inputSize = CGSize(width: CGFloat(CVPixelBufferGetWidth(capturedImage)), height: CGFloat(CVPixelBufferGetHeight(capturedImage)))
            let orientedInputSize = orientedSize(inputSize, for: exifOrientation)
            #else
            let orientationRaw: UInt32? = nil
            let orientedInputSize = CGSize(width: CGFloat(CVPixelBufferGetWidth(capturedImage)), height: CGFloat(CVPixelBufferGetHeight(capturedImage)))
            #endif

            guard let pixelBuffer = clonePixelBuffer(capturedImage) else {
                await logger.log("Camera pipeline dropped a frame because the pixel buffer could not be cloned.", level: .warning, category: "LangscapeApp.Camera")
                return
            }

            await MainActor.run {
                viewModel.handleFrame(pixelBuffer, orientationRaw: orientationRaw, orientedInputSize: orientedInputSize)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Task { await logger.log("AR session failed: \(error.localizedDescription)", level: .error, category: "LangscapeApp.Camera") }
    }
}

#if canImport(UIKit) && canImport(ImageIO)
private func exifOrientationForBackCamera(_ interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
    switch interfaceOrientation {
    case .portrait:
        return .right
    case .portraitUpsideDown:
        return .left
    case .landscapeLeft:
        return .up
    case .landscapeRight:
        return .down
    default:
        return .right
    }
}

private func orientedSize(_ size: CGSize, for orientation: CGImagePropertyOrientation) -> CGSize {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
        return CGSize(width: size.height, height: size.width)
    default:
        return size
    }
}
#endif

private func projectedRect(
    for normalizedRect: DetectionRect,
    inputImageSize: CGSize?,
    viewSize: CGSize
) -> CGRect? {
    guard let cameraRect = projectedCameraFrameRect(inputImageSize: inputImageSize, viewSize: viewSize) else {
        return nil
    }
    let dw = cameraRect.width
    let dh = cameraRect.height
    let x = cameraRect.origin.x + CGFloat(normalizedRect.origin.x) * dw
    let y = cameraRect.origin.y + CGFloat(normalizedRect.origin.y) * dh
    let w = CGFloat(normalizedRect.size.width) * dw
    let h = CGFloat(normalizedRect.size.height) * dh
    return CGRect(x: x, y: y, width: w, height: h)
}

private func projectedCameraFrameRect(inputImageSize: CGSize?, viewSize: CGSize) -> CGRect? {
    guard let imgSize = inputImageSize, imgSize.width > 0, imgSize.height > 0 else {
        return nil
    }
    let sw = viewSize.width
    let sh = viewSize.height
    let iw = CGFloat(imgSize.width)
    let ih = CGFloat(imgSize.height)
    let scale = max(sw / iw, sh / ih)
    let dw = iw * scale
    let dh = ih * scale
    let offsetX = (sw - dw) / 2
    let offsetY = (sh - dh) / 2
    return CGRect(x: offsetX, y: offsetY, width: dw, height: dh)
}

#if canImport(CoreVideo)
private func clonePixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let format = CVPixelBufferGetPixelFormatType(source)
    var output: CVPixelBuffer?
    let options: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        options as CFDictionary,
        &output
    ) == kCVReturnSuccess, let copy = output else {
        return nil
    }
    CVBufferPropagateAttachments(source, copy)
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])
    defer {
        CVPixelBufferUnlockBaseAddress(copy, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    guard let srcBase = CVPixelBufferGetBaseAddress(source),
          let dstBase = CVPixelBufferGetBaseAddress(copy) else {
        return nil
    }
    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
    let dstBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
    let rows = CVPixelBufferGetHeight(source)
    for row in 0..<rows {
        let src = srcBase.advanced(by: row * srcBytesPerRow)
        let dst = dstBase.advanced(by: row * dstBytesPerRow)
        memcpy(dst, src, min(srcBytesPerRow, dstBytesPerRow))
    }
    return copy
}
#endif

#endif
